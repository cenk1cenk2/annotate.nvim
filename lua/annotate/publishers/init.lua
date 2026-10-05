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
---@field draft? boolean the merge or pull request is a draft
---@field ids? table<string, string|integer> forge ids of the merge or pull request recorded with every posted entry

---@class annotate.PublishItem
---@field annotation annotate.Annotation
---@field kind "line"|"file"|"repository" positioned in the diff, attached to a file, or to the repository
---@field location string
---@field body string
---@field path? string new path of the file
---@field old_path? string
---@field in_diff? boolean the file is part of the diff
---@field fallback? boolean a line note that could not be positioned in the diff
---@field legend? boolean the legend of the types rather than a note
---@field update? annotate.Posted the entry of a posted note whose body changed since
---@field rewrite? boolean the type prefills the selection, its fenced block becomes a suggestion in the diff
---@field side? "new"|"old"
---@field line? integer first line on `side`
---@field line_end? integer last line on `side`
---@field new_line? integer new side line of `line`
---@field old_line? integer old side line of `line`
---@field destination? "inline"|"suggestion"|"file"|"general"|"conversation" set by the publisher's `route` along with the final `body`

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
---@field state "draft"|"queued"|"published" queued notes are only recorded and posted on submit
---@field at integer
---@field hash string SHA-1 of the posted body
---@field body string the posted body
---@field [string] any further forge ids, like `note_id`, `discussion_id` or `comment_node_id`

---@class annotate.PostedIds
---@field id? integer|string
---@field comment_url? string
---@field [string] any

---@class annotate.Verdict
---@field key "comment"|"approve"|"unapprove"|"request_changes"
---@field label string

---@class annotate.Publisher
---@field name string
---@field label string what the platform is called, like `GitLab`
---@field verdicts fun(target: annotate.Target): annotate.Verdict[], string? the verdicts the current user may give on the target, and why the others are not available
---@field match fun(url: string): boolean
---@field resolve fun(remote: annotate.Remote): annotate.Target? nil when the branch has no open merge or pull request
---@field drafts fun(target: annotate.Target): table<string, true> ids of the drafts of the current user still pending on the target
---@field post fun(target: annotate.Target, items: annotate.PublishItem[], record: fun(item: annotate.PublishItem, ids: annotate.PostedIds)) stages the items as drafts
---@field update fun(target: annotate.Target, item: annotate.PublishItem, entry: annotate.Posted): annotate.PostedIds? changes the posted body in place, nil when it no longer exists on the forge
---@field target string what a review target is called, like `Merge request`
---@field route fun(item: annotate.PublishItem): "inline"|"suggestion"|"file"|"general"|"conversation", string where the item goes on the platform and the body sent there
---@field deliver? fun(target: annotate.Target, entry: annotate.Posted): annotate.PostedIds posts a queued note on submit
---@field submit fun(target: annotate.Target, verdict: string, note?: string): table<string, annotate.PostedIds>? publishes every draft with the verdict, returning what the drafts became by draft id

---@class annotate.PublishOptions
---@field publish? boolean submit the review instead of staging it, defaults to `external.submit`
---@field verdict? "comment"|"approve"|"unapprove"|"request_changes" skips the verdict question when submitting
---@field note? string skips the summary note question when submitting, empty for none
---@field force? boolean skips the summary
---@field legend? boolean label each comment with its type and post the legend of the types, defaults to `external.legend`
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
  ---id of the synthetic annotation carrying the legend through a publish
  LEGEND = "legend",
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

--- The `external.platform` publisher, otherwise the first configured one matching the remote url.
---@param url string
---@return annotate.Publisher?
function M.find(url)
  local platform = config.options.external.platform
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

--- Hex SHA-1 of a string.
---@param text string
---@return string
function M.sha1(text)
  local bit = require("bit")
  local band, bor, bxor, bnot, rol, tohex = bit.band, bit.bor, bit.bxor, bit.bnot, bit.rol, bit.tohex
  local h0, h1, h2, h3, h4 = 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0

  local length = #text
  text = text .. "\128" .. ("\0"):rep((55 - length) % 64)
  local bits = length * 8
  for i = 7, 0, -1 do
    text = text .. string.char(math.floor(bits / 2 ^ (i * 8)) % 256)
  end

  for chunk = 1, #text, 64 do
    local w = {}
    for i = 0, 15 do
      local a, b, c, d = text:byte(chunk + i * 4, chunk + i * 4 + 3)
      w[i] = bor(bit.lshift(a, 24), bit.lshift(b, 16), bit.lshift(c, 8), d)
    end
    for i = 16, 79 do
      w[i] = rol(bxor(w[i - 3], w[i - 8], w[i - 14], w[i - 16]), 1)
    end

    local a, b, c, d, e = h0, h1, h2, h3, h4
    for i = 0, 79 do
      local f, k
      if i < 20 then
        f, k = bor(band(b, c), band(bnot(b), d)), 0x5A827999
      elseif i < 40 then
        f, k = bxor(b, c, d), 0x6ED9EBA1
      elseif i < 60 then
        f, k = bor(band(b, c), band(b, d), band(c, d)), 0x8F1BBCDC
      else
        f, k = bxor(b, c, d), 0xCA62C1D6
      end
      a, b, c, d, e = bit.tobit(rol(a, 5) + f + e + k + w[i]), a, rol(b, 30), c, d
    end

    h0, h1, h2, h3, h4 = bit.tobit(h0 + a), bit.tobit(h1 + b), bit.tobit(h2 + c), bit.tobit(h3 + d), bit.tobit(h4 + e)
  end

  return tohex(h0) .. tohex(h1) .. tohex(h2) .. tohex(h3) .. tohex(h4)
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
        lines.new[new] = { hunk = hunk, type = "new", old_pos = old, new_pos = new }
        new = new + 1
      elseif marker == "-" then
        lines.old[old] = { hunk = hunk, type = "old", old_pos = old, new_pos = new }
        old = old + 1
      elseif marker == " " then
        lines.new[new] = { hunk = hunk, old = old, old_pos = old, new_pos = new }
        lines.old[old] = { hunk = hunk, new = new, old_pos = old, new_pos = new }
        old, new = old + 1, new + 1
      end
    end
  end

  return lines
end

--- Maps annotations onto the diff of a target.
---@param annotations annotate.Annotation[]
---@param target annotate.Target
---@param legend? boolean label the bodies with their type
---@return annotate.PublishItem[]
function M.plan(annotations, target, legend)
  local export = require("annotate.export")

  local function names(sha, rev)
    return #rev >= 7 and vim.startswith(sha, rev)
  end

  return vim.tbl_map(function(annotation)
    local t = require("annotate.marks").type(annotation)
    local location = export.location(annotation)
    local item = {
      annotation = annotation,
      location = location,
      body = config.options.external.body(annotation, t, location, legend == true, require("annotate.marks").reach(annotation)),
      rewrite = t.prefill == "selection",
    }

    if annotation.id == M.LEGEND then
      return vim.tbl_extend("force", item, { kind = "repository", body = annotation.text, legend = true, rewrite = false })
    elseif not annotation.file then
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
      first = first,
      last = last,
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

--- Runs a command inside `M.async` and decodes its JSON output, returning nil and the stderr when it fails.
---@param cmd string[]
---@param body? table sent as JSON on stdin
---@return any, string?
function M.attempt(cmd, body)
  local result = M.wait(function(callback)
    M.run(cmd, body and vim.json.encode(body), callback)
  end)
  if result.code ~= 0 then
    return nil, vim.trim(result.stderr or "")
  end

  local stdout = vim.trim(result.stdout or "")

  return stdout ~= "" and vim.json.decode(stdout, { luanil = { object = true, array = true } }) or vim.empty_dict()
end

--- Whether the stderr of a failed CLI call says the thing does not exist.
---@param stderr string
---@return boolean
function M.missing(stderr)
  return stderr:find("404", 1, true) ~= nil or stderr:find("Not Found", 1, true) ~= nil
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

--- Synthetic annotation carrying the legend of the types used by the annotations, recorded in the store under `legend`.
---@param annotations annotate.Annotation[]
---@return annotate.Annotation
function M.legend(annotations)
  local cfg = config.options.external
  local lines = { cfg.legend_prompt, "" }
  for _, section in ipairs(require("annotate.export").sections(annotations)) do
    local label = ("[%s] (%s)"):format(section.type.name:upper(), section.reach)
    local prompt = config.prompt(section.type, "external", section.reach)
    table.insert(lines, prompt ~= "" and ("- **%s**: %s"):format(label, prompt) or ("- **%s**"):format(label))
  end

  return { id = M.LEGEND, type = M.LEGEND, line = 0, created_at = 0, text = table.concat(lines, "\n"), posted = store.legend.posted }
end

--- Replaces where an annotation, or the legend, was posted.
---@param annotation annotate.Annotation
---@param posted annotate.Posted[]
local function record(annotation, posted)
  if annotation.id == M.LEGEND then
    store.legend.posted = #posted > 0 and posted or nil
    annotation.posted = store.legend.posted
    store.save()
  else
    store.update(annotation.id, { posted = #posted > 0 and posted or vim.NIL })
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

--- The first line that differs between two bodies, shortened.
---@param old? string
---@param new string
---@return string
function M.change(old, new)
  if not old then
    return "body changed"
  end

  local function short(line)
    return vim.fn.strcharlen(line) > 40 and vim.fn.strcharpart(line, 0, 39) .. "…" or line
  end

  local before, after = vim.split(old, "\n", { plain = true }), vim.split(new, "\n", { plain = true })
  for index = 1, math.max(#before, #after) do
    if before[index] ~= after[index] then
      return ("line %d: `%s` -> `%s`"):format(index, short(before[index] or ""), short(after[index] or ""))
    end
  end

  return "body changed"
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

  local label = ({ file = "file comment", general = "general comment", conversation = "conversation comment" })[item.destination] or item.destination

  return item.fallback and ("%s (outside the diff)"):format(label) or label
end

--- Markdown summary of a plan in the shape of the export: the target, the totals, then each note with where it goes and the body that is sent.
---@param publisher annotate.Publisher
---@param target annotate.Target
---@param items annotate.PublishItem[]
---@param skipped { annotation: annotate.Annotation, entry: annotate.Posted }[]
---@param submit boolean
---@param legend boolean
---@param verdicts? { list: annotate.Verdict[], reason?: string } what a submit may conclude with
---@return string[]
function M.summary(publisher, target, items, skipped, submit, legend, verdicts)
  local export = require("annotate.export")
  local cfg = config.options.export

  local rows = {}
  for _, item in ipairs(items) do
    rows[item.annotation] = {
      "- Destination: " .. destination(item),
      item.update and ("- Status: update, %s on %s, %s"):format(item.update.state, target.reference, M.change(item.update.body, item.body))
        or (item.destination == "conversation" and not submit and "- Status: new, queued, posted on submit" or "- Status: new"),
      "",
      item.body,
    }
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

  local updates = count(function(item)
    return item.update ~= nil
  end)

  local totals = {}
  if updates > 0 then
    table.insert(totals, plural(updates, "update"))
  end
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
  if target.draft then
    table.insert(lines, ("- Draft: yes, comments are allowed but the %s is not ready"):format(publisher.target:lower()))
  end
  if submit and verdicts then
    local labels = vim.tbl_map(function(v)
      return v.label
    end, verdicts.list)
    vim.list_extend(lines, {
      "",
      "## Review",
      "",
      #labels == 1 and ("- Verdict: %s%s"):format(labels[1], verdicts.reason and (" (%s)"):format(verdicts.reason) or "")
        or ("- Verdict: chosen next from %s%s"):format(table.concat(labels, ", "), verdicts.reason and (" (%s)"):format(verdicts.reason) or ""),
      "- Note: chosen next",
    })
  end
  vim.list_extend(lines, {
    "",
    "## Summary",
    "",
    ("- To post: %d%s"):format(#items, #totals > 0 and (" (%s)"):format(table.concat(totals, ", ")) or ""),
    ("- Skipped: %d (already draft or published)"):format(#skipped),
    ("- Legend: %s"):format(legend and "on, comments are labelled with their type" or "off"),
  })

  local note = vim.iter(vim.tbl_keys(rows)):find(function(annotation)
    return annotation.id == M.LEGEND
  end)
  if note then
    vim.list_extend(lines, { "", "## Legend", "" })
    for _, row in ipairs(rows[note]) do
      vim.list_extend(lines, vim.split(row, "\n", { plain = true }))
    end
    rows[note] = nil
  end

  for index, section in ipairs(export.sections(vim.tbl_keys(rows))) do
    if index > 1 then
      vim.list_extend(lines, { "", cfg.separator })
    end
    vim.list_extend(lines, { "", ("## %s"):format(cfg.label(section.type, section.reach)) })

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
  for action, list in pairs(cfg.external.summary_keys) do
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

--- Asks for the verdict, then the review note, nil when either is cancelled.
---@param publisher annotate.Publisher
---@param verdicts { list: annotate.Verdict[], reason?: string }
---@param opts annotate.PublishOptions
---@return string?, string?
local function review(publisher, verdicts, opts)
  local verdict = opts.verdict or #verdicts.list == 1 and verdicts.list[1].key or nil
  if not verdict then
    local chosen = M.wait(function(callback)
      vim.ui.select(verdicts.list, {
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

  if not vim.iter(verdicts.list):any(function(v)
    return v.key == verdict
  end) then
    error(("annotate: the %s verdict is not available on this %s%s"):format(verdict, publisher.target:lower(), verdicts.reason and (": %s"):format(verdicts.reason) or ""), 0)
  end

  local note = opts.note
  if note == nil then
    local _, text = M.wait(function(callback)
      require("annotate.input").open({ title = "Review note" }, callback)
    end)
    if text == nil then
      return nil
    end
    note = text
  end

  return verdict, note ~= "" and note or nil
end

--- Posts the annotations of the repository to the merge or pull request of the current branch as review comments.
---@param opts? annotate.PublishOptions
function M.publish(opts)
  opts = opts or {}
  local cfg = config.options.external
  local submit = opts.publish
  if submit == nil then
    submit = cfg.submit
  end
  local legend = opts.legend
  if legend == nil then
    legend = cfg.legend
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
      return notify(("No publisher matches remote %s: %s, set external.platform for a self-hosted forge."):format(remote.name, remote.url), vim.log.levels.WARN)
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
    local candidates = legend and #annotations > 0 and vim.list_extend({ M.legend(annotations) }, annotations) or annotations
    for _, annotation in ipairs(candidates) do
      local entry, index = M.posted(annotation, publisher.name, target)
      if entry and entry.state == "draft" and not drafts[tostring(entry.id)] then
        local posted = vim.deepcopy(annotation.posted)
        table.remove(posted, index)
        record(annotation, posted)
      end
    end

    local items, skipped = {}, {}
    for _, item in ipairs(M.plan(candidates, target, legend)) do
      item.destination, item.body = publisher.route(item)

      local entry = M.posted(item.annotation, publisher.name, target)
      if not entry then
        table.insert(items, item)
      elseif not entry.hash or entry.hash == M.sha1(item.body) then
        table.insert(skipped, { annotation = item.annotation, entry = entry })
      else
        item.update = entry
        table.insert(items, item)
      end
    end

    if #items == 0 and not submit then
      return notify(("Every annotation is already posted to %s %s, %s skipped."):format(target.reference, target.title, plural(#skipped, "note")))
    end

    local verdicts
    if submit then
      local list, reason = publisher.verdicts(target)
      verdicts = { list = list, reason = reason }
    end

    if not opts.force and cfg.summary then
      local proceed = M.wait(function(callback)
        M.confirm(submit and "Submit review" or "Stage drafts", M.summary(publisher, target, items, skipped, submit, legend, verdicts), callback)
      end)
      if not proceed then
        return notify("Publishing was cancelled.", vim.log.levels.WARN)
      end
    end

    local verdict, note
    if submit then
      verdict, note = review(publisher, verdicts, opts)
      if not verdict then
        return notify("Submitting the review was cancelled.", vim.log.levels.WARN)
      end
    end

    notify(("Publishing %s to %s %s %s."):format(plural(#items, "note"), publisher.label, target.reference, target.title))

    local fresh, updated = {}, 0
    for _, item in ipairs(items) do
      local entry = item.update
      if entry then
        local ids = publisher.update(target, item, entry)
        local posted = vim.deepcopy(item.annotation.posted)
        local _, index = M.posted(item.annotation, publisher.name, target)
        if ids then
          updated = updated + 1
          posted[index] = vim.tbl_extend("force", posted[index], ids, { hash = M.sha1(item.body), body = item.body, at = os.time() })
        else
          table.remove(posted, index)
          table.insert(fresh, item)
        end
        record(item.annotation, posted)
      else
        table.insert(fresh, item)
      end
    end

    local posted = 0
    publisher.post(target, fresh, function(item, ids)
      posted = posted + 1
      record(
        item.annotation,
        vim.list_extend(vim.deepcopy(item.annotation.posted or {}), {
          vim.tbl_extend("force", { state = "draft" }, target.ids or {}, {
            platform = publisher.name,
            remote_url = remote.url,
            project = remote.path,
            target = target.id,
            branch = target.branch,
            target_branch = target.target_branch,
            title = target.title,
            reference = target.reference,
            url = target.url,
            hash = M.sha1(item.body),
            body = item.body,
            at = os.time(),
          }, ids),
        })
      )
    end)

    if submit then
      local published = publisher.submit(target, verdict, note) or {}
      for _, annotation in ipairs(vim.list_extend({ store.legend }, store.all())) do
        local entry = M.posted(annotation, publisher.name, target)
        if entry and entry.state == "draft" then
          entry.state = "published"
          for key, value in pairs(published[tostring(entry.id)] or {}) do
            entry[key] = entry[key] or value
          end
        elseif entry and entry.state == "queued" then
          entry = vim.tbl_extend("force", entry, publisher.deliver(target, entry), { state = "published", at = os.time() })
          local entries = vim.deepcopy(annotation.posted)
          local _, index = M.posted(annotation, publisher.name, target)
          entries[index] = entry
          record(annotation.id and annotation or vim.tbl_extend("force", annotation, { id = M.LEGEND }), entries)
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
      ("%s %s: %d %s, %d updated, %d skipped as already posted, %d fell back to general comments%s%s."):format(
        target.reference,
        target.title,
        posted,
        submit and "submitted" or "staged",
        updated,
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
