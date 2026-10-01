---@class annotate.Remote
---@field name string
---@field url string
---@field host string
---@field path string repository path on the host, `owner/repo` or `group/subgroup/project`
---@field branch string branch name on the remote

---@class annotate.DiffLine
---@field hunk integer
---@field old? integer old side line of a context line on the new side
---@field new? integer new side line of a context line on the old side

---@class annotate.DiffLines
---@field new table<integer, annotate.DiffLine>
---@field old table<integer, annotate.DiffLine>

---@class annotate.DiffFile
---@field new_path string
---@field old_path string
---@field lines annotate.DiffLines

---@class annotate.Target
---@field id integer merge request iid or pull request number
---@field reference string `!iid` or `#number`
---@field title string
---@field url string
---@field branch string source branch
---@field target_branch string
---@field head string sha the diff ends at
---@field base string sha the old side of the diff shows
---@field files annotate.DiffFile[]
---@field remote annotate.Remote

---@class annotate.PublishItem
---@field annotation annotate.Annotation
---@field kind "line"|"file"|"repository" positioned in the diff, attached to a file, or to the repository
---@field location string
---@field body string
---@field path? string new path of the file
---@field old_path? string
---@field in_diff? boolean the file is part of the diff
---@field fallback? boolean a line note that could not be positioned in the diff
---@field rewrite? boolean the type prefills the selection, its fenced block becomes a suggestion in the diff
---@field side? "new"|"old"
---@field line? integer first line on `side`
---@field line_end? integer last line on `side`
---@field new_line? integer new side line of `line`
---@field old_line? integer old side line of `line`
---@field destination? "inline"|"suggestion"|"file"|"general"|"body" set by the publisher's `route` along with the final `body`

---@class annotate.Posted
---@field platform string
---@field remote_url string
---@field project string
---@field target integer
---@field branch string
---@field target_branch string
---@field title string
---@field reference string `!iid` or `#number`
---@field url string of the merge or pull request
---@field comment_url? string
---@field id integer|string draft note, review comment, or review id
---@field state "draft"|"published"
---@field at integer

---@class annotate.Verdict
---@field key "comment"|"approve"|"request_changes"
---@field label string

---@class annotate.Publisher
---@field name string
---@field label string what the platform is called, like `GitLab`
---@field verdicts annotate.Verdict[]
---@field match fun(url: string): boolean
---@field resolve fun(remote: annotate.Remote): annotate.Target? nil when the branch has no open merge or pull request
---@field drafts fun(target: annotate.Target): table<string, true> ids of the drafts of the current user still pending on the target
---@field post fun(target: annotate.Target, items: annotate.PublishItem[], record: fun(item: annotate.PublishItem, id: integer|string, url?: string)) stages the items as drafts
---@field target string what a review target is called, like `Merge request`
---@field route fun(item: annotate.PublishItem): "inline"|"suggestion"|"file"|"general"|"body", string where the item goes on the platform and the body sent there
---@field submit fun(target: annotate.Target, verdict: string, note?: string): table<string, string>? publishes every draft with the verdict, returning comment urls by draft id

---@class annotate.PublishOptions
---@field publish? boolean submit the review instead of staging it, defaults to `publish.submit`
---@field verdict? "comment"|"approve"|"request_changes" skips the verdict question when submitting
---@field note? string skips the summary note question when submitting, empty for none
---@field force? boolean skips the summary
---@field clear? boolean archive the store after everything was posted
---@field types? string[] subset of type keys to publish
---@field remote? string remote to publish to instead of the branch upstream

local M = {
  ---@type table<string, annotate.Publisher>
  registry = {
    gitlab = require("annotate.publishers.gitlab"),
    github = require("annotate.publishers.github"),
  },
  ---format is repository root: remote chosen for a branch without an upstream
  ---@type table<string, string>
  remotes = {},
}

local config = require("annotate.config")
local git = require("annotate.git")
local log = require("annotate.log")
local store = require("annotate.store")

---@param message string
---@param level? integer
local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = config.options.notify.title })
end

--- Registers a publisher so it can be referenced by name in `config.publishers`.
---@param publisher annotate.Publisher
---@return annotate.Publisher
function M.register(publisher)
  M.registry[publisher.name] = publisher

  return publisher
end

--- Publishers in the configured order.
---@return annotate.Publisher[]
function M.list()
  return vim.tbl_map(function(publisher)
    if type(publisher) == "table" then
      return publisher
    end

    return M.registry[publisher] or error(("annotate: unknown publisher: %s"):format(publisher))
  end, config.options.publishers)
end

--- The `publish.platform` publisher, otherwise the first configured one matching the remote url.
---@param url string
---@return annotate.Publisher?
function M.find(url)
  local platform = config.options.publish.platform
  for _, publisher in ipairs(M.list()) do
    if platform and publisher.name == platform or not platform and publisher.match(url) then
      return publisher
    end
  end
end

--- Host and repository path of a remote url, for scp-like and URL forms.
---@param url string
---@return string? host, string? path
function M.parse_remote(url)
  local host, path = url:match("^%a[%w+.-]*://[^/]-@?([^@/:]+)[:%d]*/(.+)$")
  if not host then
    host, path = url:match("^[^/]-@?([^@/:]+):(.+)$")
  end
  if not host then
    return nil
  end

  return host, (path:gsub("%.git/?$", ""):gsub("/$", ""))
end

--- Line maps of a unified diff, keyed by line number on each side, with the line on the other side for context lines.
---@param patch? string
---@return annotate.DiffLines
function M.parse_diff(patch)
  local lines = { new = {}, old = {} }
  local hunk, old, new = 0, 0, 0

  for _, line in ipairs(vim.split(patch or "", "\n", { plain = true })) do
    local old_start, new_start = line:match("^@@ %-(%d+),?%d* %+(%d+),?%d* @@")
    if old_start then
      hunk, old, new = hunk + 1, tonumber(old_start), tonumber(new_start)
    elseif hunk > 0 then
      local marker = line:sub(1, 1)
      if marker == "+" then
        lines.new[new] = { hunk = hunk }
        new = new + 1
      elseif marker == "-" then
        lines.old[old] = { hunk = hunk }
        old = old + 1
      elseif marker == " " then
        lines.new[new] = { hunk = hunk, old = old }
        lines.old[old] = { hunk = hunk, new = new }
        old, new = old + 1, new + 1
      end
    end
  end

  return lines
end

--- Maps annotations onto the diff of a target.
---@param annotations annotate.Annotation[]
---@param target annotate.Target
---@return annotate.PublishItem[]
function M.plan(annotations, target)
  local export = require("annotate.export")

  local function names(sha, rev)
    return #rev >= 7 and vim.startswith(sha, rev)
  end

  return vim.tbl_map(function(annotation)
    local t = config.type(annotation.type) or { key = annotation.type, name = annotation.type, prompt = "" }
    local location = export.location(annotation)
    local item = { annotation = annotation, location = location, body = config.options.publish.body(annotation, t, location), rewrite = t.prefill == "selection" }

    if not annotation.file then
      return vim.tbl_extend("force", item, { kind = "repository" })
    end

    local side
    if not annotation.rev or names(target.head, annotation.rev) then
      side = "new"
    elseif names(target.base, annotation.rev) then
      side = "old"
    end

    local file = vim.iter(target.files):find(function(f)
      return side == "old" and f.old_path == annotation.file or side ~= "old" and f.new_path == annotation.file
    end)

    item = vim.tbl_extend("force", item, { kind = "file", path = file and file.new_path or annotation.file, old_path = file and file.old_path, in_diff = file ~= nil })
    if annotation.line == 0 then
      return item
    end

    local lines = side and file and file.lines[side]
    local first = lines and lines[annotation.line]
    local last = lines and lines[annotation.line_end or annotation.line]
    if not (first and last and first.hunk == last.hunk) then
      return vim.tbl_extend("force", item, { fallback = true })
    end

    return vim.tbl_extend("force", item, {
      kind = "line",
      side = side,
      line = annotation.line,
      line_end = annotation.line_end or annotation.line,
      new_line = side == "new" and annotation.line or first.new,
      old_line = side == "old" and annotation.line or first.old,
    })
  end, annotations)
end

--- Turns the first fenced block of a rewrite on the new side of the diff into a suggestion, nil when it has none.
---@param item annotate.PublishItem
---@param info string info string of the suggestion fence, like `suggestion`
---@return string?
function M.suggest(item, info)
  if not (item.rewrite and item.kind == "line" and item.side == "new") then
    return nil
  end

  local lines = vim.split(item.body, "\n", { plain = true })
  for index, line in ipairs(lines) do
    local indent, fence = line:match("^(%s*)(```+)[^`]*$")
    if fence then
      lines[index] = indent .. fence .. info

      return table.concat(lines, "\n")
    end
  end
end

--- Body prefixed with the location, for a note that is not positioned on its lines.
---@param item annotate.PublishItem
---@return string
function M.located(item)
  return ("`%s`\n\n%s"):format(item.location, item.body)
end

--- Runs a command in the repository root, calling back on the main loop.
---@param cmd string[]
---@param stdin? string
---@param callback fun(result: vim.SystemCompleted)
function M.run(cmd, stdin, callback)
  log.debug(("publish run: %s"):format(table.concat(cmd, " ")))

  vim.system(cmd, { text = true, stdin = stdin, cwd = git.root() }, function(result)
    vim.schedule(function()
      callback(result)
    end)
  end)
end

--- Calls `start` with a callback and suspends the running `M.async` coroutine until it is called.
---@param start fun(callback: fun(...))
---@return ...
function M.wait(start)
  local co = coroutine.running()
  local result, waiting

  start(function(...)
    result = vim.F.pack_len(...)
    if waiting then
      M.resume(co)
    end
  end)

  if not result then
    waiting = true
    coroutine.yield()
  end

  return vim.F.unpack_len(result)
end

---@param co thread
function M.resume(co)
  local ok, err = coroutine.resume(co)
  if not ok then
    log.error(("publish failed: %s"):format(err))
    notify(tostring(err), vim.log.levels.ERROR)
  end
end

--- Runs `fn` as a coroutine that can `M.wait`, reporting what it raises.
---@param fn fun()
function M.async(fn)
  M.resume(coroutine.create(fn))
end

--- Runs a command inside `M.async`, raising with its stderr when it fails.
---@param cmd string[]
---@param stdin? string
---@return string stdout
function M.exec(cmd, stdin)
  local result = M.wait(function(callback)
    M.run(cmd, stdin, callback)
  end)

  if result.code ~= 0 then
    error(("%s failed: %s"):format(table.concat(cmd, " "), vim.trim(result.stderr or "")), 0)
  end

  return vim.trim(result.stdout or "")
end

--- Runs a command inside `M.async` and decodes its JSON output.
---@param cmd string[]
---@param body? table sent as JSON on stdin
---@return any
function M.json(cmd, body)
  local stdout = M.exec(cmd, body and vim.json.encode(body))
  if stdout == "" then
    return nil
  end

  return vim.json.decode(stdout, { luanil = { object = true, array = true } })
end

--- Runs a git command inside `M.async`, nil when it fails or prints nothing.
---@param args string[]
---@return string?
function M.git(args)
  local result = M.wait(function(callback)
    M.run(vim.list_extend({ "git" }, args), nil, callback)
  end)
  local stdout = vim.trim(result.stdout or "")

  return result.code == 0 and stdout ~= "" and stdout or nil
end

--- Remote of the current branch inside `M.async`: `name`, its upstream, the only remote, or the one the user chooses once per repository.
---@param name? string
---@return annotate.Remote?
function M.remote(name)
  local branch = M.git({ "symbolic-ref", "--short", "HEAD" }) or error("annotate: HEAD is detached, check out the branch of the review", 0)
  local upstream = M.git({ "config", "--get", ("branch.%s.remote"):format(branch) })
  local merge = upstream and M.git({ "config", "--get", ("branch.%s.merge"):format(branch) })

  name = name or upstream ~= "." and upstream or M.remotes[git.root()]
  if not name then
    local remotes = vim.split(M.git({ "remote" }) or "", "\n", { trimempty = true })
    if #remotes == 0 then
      return notify("The repository has no remote to publish to.", vim.log.levels.WARN)
    end

    if #remotes == 1 then
      name = remotes[1]
    else
      local urls = {}
      for _, remote in ipairs(remotes) do
        urls[remote] = M.git({ "remote", "get-url", remote }) or ""
      end

      name = M.wait(function(callback)
        vim.ui.select(remotes, {
          prompt = ("%s: remote to publish to"):format(config.options.notify.title),
          format_item = function(remote)
            return ("%s  %s"):format(remote, urls[remote])
          end,
        }, callback)
      end)
      if not name then
        return nil
      end

      M.remotes[git.root()] = name
    end
  end

  local url = M.git({ "remote", "get-url", name }) or error(("annotate: unknown remote: %s"):format(name), 0)
  local host, path = M.parse_remote(url)
  if not host then
    error(("annotate: can not read the host and repository of remote %s: %s"):format(name, url), 0)
  end

  return {
    name = name,
    url = url,
    host = host,
    path = path,
    branch = name == upstream and merge and merge:gsub("^refs/heads/", "") or branch,
  }
end

--- The entry recording an annotation on a target, if it was posted there.
---@param annotation annotate.Annotation
---@param platform string
---@param target annotate.Target
---@return annotate.Posted?, integer?
function M.posted(annotation, platform, target)
  for index, entry in ipairs(annotation.posted or {}) do
    if entry.platform == platform and entry.project == target.remote.path and entry.target == target.id then
      return entry, index
    end
  end
end

--- One line describing where an annotation was posted.
---@param entry annotate.Posted
---@return string
function M.describe(entry)
  return ("%s  %s  %s  %s"):format(entry.state, entry.reference, entry.branch, entry.comment_url or entry.url)
end

---@param count integer
---@param noun string
---@return string
local function plural(count, noun)
  return ("%d %s%s"):format(count, noun, count == 1 and "" or "s")
end

--- What a destination is called in the summary.
---@param item annotate.PublishItem
---@return string
local function destination(item)
  if item.destination == "inline" then
    return ("inline, %s side"):format(item.side)
  elseif item.destination == "suggestion" then
    return "suggestion"
  end

  local label = ({ file = "file comment", general = "general comment", body = "review body" })[item.destination] or item.destination

  return item.fallback and ("%s (outside the diff)"):format(label) or label
end

--- Markdown summary of a plan in the shape of the export: the target, the totals, then each note with where it goes and the body that is sent.
---@param publisher annotate.Publisher
---@param target annotate.Target
---@param items annotate.PublishItem[]
---@param skipped { annotation: annotate.Annotation, entry: annotate.Posted }[]
---@param submit boolean
---@return string[]
function M.summary(publisher, target, items, skipped, submit)
  local export = require("annotate.export")
  local cfg = config.options.export

  local rows = {}
  for _, item in ipairs(items) do
    rows[item.annotation] = { "- Destination: " .. destination(item), "- Status: new", "", item.body }
  end
  for _, skip in ipairs(skipped) do
    rows[skip.annotation] = { ("- Status: skipped, %s on %s %s"):format(skip.entry.state, target.reference, skip.entry.comment_url or skip.entry.url) }
  end

  local function count(predicate)
    return #vim.tbl_filter(predicate, items)
  end
  local suggestions = count(function(item)
    return item.destination == "suggestion"
  end)
  local fallbacks = count(function(item)
    return item.fallback
  end)
  local unsuggested = count(function(item)
    return item.rewrite and item.destination ~= "suggestion"
  end)

  local totals = {}
  if suggestions > 0 then
    table.insert(totals, plural(suggestions, "suggestion"))
  end
  if fallbacks > 0 then
    table.insert(totals, ("%d outside the diff"):format(fallbacks))
  end
  if unsuggested > 0 then
    table.insert(totals, ("%s without a suggestion"):format(plural(unsuggested, "rewrite")))
  end

  local lines = {
    ("# %s"):format(submit and "Submit review" or "Stage drafts"),
    "",
    "## Target",
    "",
    ("- Platform: %s"):format(publisher.label),
    ("- %s: %s %s"):format(publisher.target, target.reference, target.title),
    ("- Branches: `%s` -> `%s`"):format(target.branch, target.target_branch),
    ("- URL: %s"):format(target.url),
    ("- Head: `%s` (matches local HEAD)"):format(target.head:sub(1, 11)),
  }
  if submit then
    vim.list_extend(lines, { "", "## Review", "", "- Verdict and note: chosen next" })
  end
  vim.list_extend(lines, {
    "",
    "## Summary",
    "",
    ("- To post: %d%s"):format(#items, #totals > 0 and (" (%s)"):format(table.concat(totals, ", ")) or ""),
    ("- Skipped: %d (already draft or published)"):format(#skipped),
  })

  for index, section in ipairs(export.sections(vim.tbl_keys(rows))) do
    if index > 1 then
      vim.list_extend(lines, { "", cfg.separator })
    end
    vim.list_extend(lines, { "", ("## %s"):format(cfg.label(section.type)) })

    for _, annotation in ipairs(section.annotations) do
      vim.list_extend(lines, { "", cfg.heading(annotation, section.type, export.location(annotation)), "" })
      for _, row in ipairs(rows[annotation]) do
        vim.list_extend(lines, vim.split(row, "\n", { plain = true }))
      end
    end
  end

  return lines
end

--- Shows the summary in a float, or through `vim.ui.select` without snacks.nvim, calling back whether to proceed.
---@param title string
---@param lines string[]
---@param callback fun(proceed: boolean)
function M.confirm(title, lines, callback)
  local ok, snacks = pcall(require, "snacks")
  if not ok then
    return vim.ui.select({ "Proceed", "Cancel" }, { prompt = ("%s\n\n%s"):format(title, table.concat(lines, "\n")) }, function(choice)
      callback(choice == "Proceed")
    end)
  end

  local cfg = config.options
  local proceed = false
  local keys = {}
  for action, list in pairs(cfg.publish.summary_keys) do
    for _, key in ipairs(list) do
      keys[key] = function(self)
        proceed = action == "proceed"
        self:close()
      end
    end
  end

  snacks.win({
    position = "float",
    width = cfg.show.max_width,
    height = math.min(#lines, cfg.show.max_height),
    border = cfg.show.border or cfg.input.border,
    title = (" %s "):format(title),
    title_pos = "center",
    enter = true,
    text = lines,
    ft = "markdown",
    bo = { modifiable = false },
    wo = { wrap = true, linebreak = true },
    keys = keys,
    on_close = function()
      vim.schedule(function()
        callback(proceed)
      end)
    end,
  })
end

--- Asks for the verdict and the summary note of a submit, nil when the verdict is cancelled.
---@param publisher annotate.Publisher
---@param opts annotate.PublishOptions
---@return string?, string?
local function review(publisher, opts)
  local verdict = opts.verdict
  if not verdict then
    local chosen = M.wait(function(callback)
      vim.ui.select(publisher.verdicts, {
        prompt = ("%s: submit the review as"):format(config.options.notify.title),
        format_item = function(v)
          return v.label
        end,
      }, callback)
    end)
    verdict = chosen and chosen.key
  end
  if not verdict then
    return nil
  end

  if not vim.iter(publisher.verdicts):any(function(v)
    return v.key == verdict
  end) then
    error(("annotate: %s has no %s verdict"):format(publisher.label, verdict), 0)
  end

  local note = opts.note
  if note == nil then
    local _, text = M.wait(function(callback)
      require("annotate.input").open({ title = "Review note" }, callback)
    end)
    note = text
  end

  return verdict, note ~= "" and note or nil
end

--- Posts the annotations of the repository to the merge or pull request of the current branch as review comments.
---@param opts? annotate.PublishOptions
function M.publish(opts)
  opts = opts or {}
  local cfg = config.options.publish
  local submit = opts.publish
  if submit == nil then
    submit = cfg.submit
  end

  if not git.root() then
    return notify(("Not inside a git repository: %s"):format(vim.fn.getcwd()), vim.log.levels.WARN)
  end

  local annotations = vim.tbl_filter(function(annotation)
    return not opts.types or vim.list_contains(opts.types, annotation.type)
  end, store.all())
  if #annotations == 0 and not submit then
    return notify("There are no annotations to publish.", vim.log.levels.WARN)
  end

  M.async(function()
    local remote = M.remote(opts.remote)
    if not remote then
      return
    end

    local publisher = M.find(remote.url)
    if not publisher then
      return notify(("No publisher matches remote %s: %s, set publish.platform for a self-hosted forge."):format(remote.name, remote.url), vim.log.levels.WARN)
    end

    local target = publisher.resolve(remote)
    if not target then
      return notify(("There is no open %s review for %s on %s."):format(publisher.label, remote.branch, remote.name), vim.log.levels.WARN)
    end

    local head = M.git({ "rev-parse", "HEAD" })
    if head ~= target.head then
      return notify(
        ("HEAD %s is not the head %s of %s %s, push or pull first: lines may not match the diff."):format(
          (head or "?"):sub(1, 11),
          target.head:sub(1, 11),
          target.reference,
          target.url
        ),
        vim.log.levels.WARN
      )
    end

    local drafts = publisher.drafts(target)
    local pending, skipped = {}, {}
    for _, annotation in ipairs(annotations) do
      local entry, index = M.posted(annotation, publisher.name, target)
      if entry and entry.state == "draft" and not drafts[tostring(entry.id)] then
        local posted = vim.deepcopy(annotation.posted)
        table.remove(posted, index)
        store.update(annotation.id, { posted = #posted > 0 and posted or vim.NIL })
        entry = nil
      end

      if entry then
        table.insert(skipped, { annotation = annotation, entry = entry })
      else
        table.insert(pending, annotation)
      end
    end

    if #pending == 0 and not submit then
      return notify(("Every annotation is already posted to %s %s, %s skipped."):format(target.reference, target.title, plural(#skipped, "note")))
    end

    local items = M.plan(pending, target)
    for _, item in ipairs(items) do
      item.destination, item.body = publisher.route(item)
    end

    if not opts.force and cfg.summary then
      local proceed = M.wait(function(callback)
        M.confirm(submit and "Submit review" or "Stage drafts", M.summary(publisher, target, items, skipped, submit), callback)
      end)
      if not proceed then
        return notify("Publishing was cancelled.", vim.log.levels.WARN)
      end
    end

    local verdict, note
    if submit then
      verdict, note = review(publisher, opts)
      if not verdict then
        return notify("Submitting the review was cancelled.", vim.log.levels.WARN)
      end
    end

    notify(("Publishing %s to %s %s %s."):format(plural(#items, "note"), publisher.label, target.reference, target.title))

    local posted = 0
    publisher.post(target, items, function(item, id, url)
      posted = posted + 1
      store.update(item.annotation.id, {
        posted = vim.list_extend(vim.deepcopy(item.annotation.posted or {}), {
          {
            platform = publisher.name,
            remote_url = remote.url,
            project = remote.path,
            target = target.id,
            branch = target.branch,
            target_branch = target.target_branch,
            title = target.title,
            reference = target.reference,
            url = target.url,
            comment_url = url,
            id = id,
            state = "draft",
            at = os.time(),
          },
        }),
      })
    end)

    if submit then
      local urls = publisher.submit(target, verdict, note) or {}
      for _, annotation in ipairs(store.all()) do
        local entry = M.posted(annotation, publisher.name, target)
        if entry and entry.state == "draft" then
          entry.state = "published"
          entry.comment_url = entry.comment_url or urls[tostring(entry.id)]
        end
      end
      store.save()
    end

    local fallbacks = #vim.tbl_filter(function(item)
      return item.fallback
    end, items)
    local unsuggested = #vim.tbl_filter(function(item)
      return item.rewrite and item.destination ~= "suggestion"
    end, items)

    log.info(("published: platform=%s target=%s #posted=%d #skipped=%d verdict=%s"):format(publisher.name, target.id, posted, #skipped, tostring(verdict)))
    notify(
      ("%s %s: %d %s, %d skipped as already posted, %d fell back to general comments%s%s."):format(
        target.reference,
        target.title,
        posted,
        submit and "submitted" or "staged",
        #skipped,
        fallbacks,
        unsuggested > 0 and (", %s without a suggestion"):format(plural(unsuggested, "rewrite")) or "",
        verdict and (", %s"):format(verdict:gsub("_", " ")) or ""
      )
    )

    if opts.clear then
      store.archive()
      require("annotate.marks").clear()
    end
  end)
end

return M
