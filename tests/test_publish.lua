local H = dofile("tests/helpers.lua")
local eq = MiniTest.expect.equality

local config = require("annotate.config")
local input = require("annotate.input")
local publishers = require("annotate.publishers")
local store = require("annotate.store")

local run = publishers.run
local select = vim.ui.select
local notify = vim.notify
local open = input.open

local HEAD = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
local BASE = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
local START = "cccccccccccccccccccccccccccccccccccccccc"

local PATCH = table.concat({
  "@@ -1,4 +1,5 @@",
  " one",
  "-two",
  "+TWO",
  "+extra",
  " three",
  " four",
  "@@ -20,2 +21,3 @@",
  " twenty",
  "+new",
  " twentyone",
}, "\n")

---@type { cmd: string[], method: string, endpoint?: string, body?: table }[]
local calls
---@type string[]
local messages
---@type table<string, string>
local git

--- Fake GitLab project holding the merge request, its drafts and its notes.
local function gitlab()
  local forge = { iid = 5, drafts = {}, notes = {}, next = 100, approved = false, approvals = { user_can_approve = true, user_has_approved = false } }

  function forge.handle(endpoint, method, body)
    local path = endpoint:gsub("^projects/[^/]+/", "")
    if path == "graphql" and body.query == publishers.registry.gitlab.permissions then
      return {
        data = {
          currentUser = { username = "me" },
          project = {
            mergeRequest = {
              discussionLocked = forge.locked or false,
              userPermissions = { createNote = not forge.locked, canApprove = forge.approvals.user_can_approve },
              approvedBy = { nodes = forge.approvals.user_has_approved and { { username = "me" } } or {} },
              reviewers = { nodes = forge.reviewer == false and {} or { { username = "me", mergeRequestInteraction = { reviewState = forge.review_state or "UNREVIEWED" } } } },
            },
          },
        },
      }
    elseif path == "graphql" and body.query == publishers.registry.gitlab.add_reviewer then
      forge.reviewer = body.variables.username

      return { data = { mergeRequestSetReviewers = { errors = {} } } }
    elseif path == "graphql" then
      forge.review_state = "REQUESTED_CHANGES"

      return { data = { mergeRequestRequestChanges = { errors = {} } } }
    elseif path:match("^merge_requests%?") then
      return { { iid = forge.iid } }
    elseif path == ("merge_requests/%d"):format(forge.iid) then
      return {
        id = 9000 + forge.iid,
        iid = forge.iid,
        project_id = 42,
        title = "Add the thing",
        web_url = ("https://gitlab.example.com/group/sub/project/-/merge_requests/%d"):format(forge.iid),
        source_branch = "feature",
        target_branch = "main",
        diff_refs = { base_sha = BASE, start_sha = START, head_sha = HEAD },
      }
    elseif path:match("/diffs$") then
      return { { new_path = "a.lua", old_path = "a.lua", diff = PATCH } }
    elseif path:match("/draft_notes$") and method == "GET" then
      return forge.drafts
    elseif path:match("/draft_notes$") then
      forge.next = forge.next + 1
      local draft = vim.tbl_extend("force", body, { id = forge.next })
      table.insert(forge.drafts, draft)

      return draft
    elseif path:match("/draft_notes/%d+$") then
      local draft = vim.iter(forge.drafts):find(function(d)
        return d.id == tonumber(path:match("(%d+)$"))
      end)
      if not draft then
        return nil, "glab: 404 Not Found"
      end
      draft.note = body.note

      return draft
    elseif path:match("/bulk_publish$") then
      for _, draft in ipairs(forge.drafts) do
        table.insert(forge.notes, { id = draft.id + 1000, body = draft.note })
      end
      forge.drafts = {}
    elseif path:match("/notes$") then
      table.insert(forge.notes, { id = 1, body = body.body })

      return {}
    elseif path:match("/notes/%d+$") then
      local note = vim.iter(forge.notes):find(function(n)
        return n.id == tonumber(path:match("(%d+)$"))
      end)
      if not note then
        return nil, "glab: 404 Not Found"
      end
      note.body = body.body

      return note
    elseif path:match("/discussions%?") then
      return vim.tbl_map(function(n)
        return { id = "d" .. n.id, notes = { n } }
      end, forge.notes)
    elseif path:match("/approvals$") then
      return forge.approvals
    elseif path:match("/unapprove$") then
      forge.approved = false
    elseif path:match("/approve$") then
      forge.approved = body.sha
    end
  end

  return forge
end

--- Fake GitHub repository holding the pull request and the pending review of the current user.
local function github()
  local forge = { number = 7, review = nil, comments = {}, next = 200, author = "someone", draft = false }

  function forge.handle(endpoint, _, body)
    local pulls = ("repos/owner/repo/pulls/%d"):format(forge.number)
    if endpoint == "user" then
      return { login = "me" }
    elseif endpoint == pulls .. "/files?per_page=100" then
      return { { { filename = "a.lua", patch = PATCH } } }
    elseif endpoint == pulls .. "/reviews?per_page=100" then
      return { forge.review and { vim.tbl_extend("force", forge.review, { state = "PENDING", user = { login = "me" } }) } or {} }
    elseif endpoint:match("/comments%?per_page=100$") then
      return { forge.comments }
    elseif endpoint == pulls .. "/reviews" then
      forge.next = forge.next + 1
      forge.review = { id = forge.next, node_id = "R" .. forge.next, body = body.body, html_url = "https://github.com/owner/repo/pull/7#review", event = body.event }

      return forge.review
    elseif forge.review and endpoint == ("%s/reviews/%d"):format(pulls, forge.review.id) then
      forge.review.body = body.body

      return forge.review
    elseif endpoint:match("^repos/owner/repo/pulls/comments/%d+$") then
      local comment = vim.iter(forge.comments):find(function(c)
        return c.id == tonumber(endpoint:match("(%d+)$"))
      end)
      if not comment then
        return nil, "gh: Not Found (HTTP 404)"
      end
      comment.body = body.body

      return { id = comment.id, html_url = "https://github.com/c/" .. comment.id }
    elseif endpoint == ("repos/owner/repo/issues/%d/comments"):format(forge.number) then
      forge.next = forge.next + 1
      local comment = { id = forge.next, node_id = "IC" .. forge.next, body = body.body, html_url = "https://github.com/i/" .. forge.next }
      forge.conversation = forge.conversation or {}
      table.insert(forge.conversation, comment)

      return comment
    elseif endpoint:match("^repos/owner/repo/issues/comments/%d+$") then
      local comment = vim.iter(forge.conversation or {}):find(function(c)
        return c.id == tonumber(endpoint:match("(%d+)$"))
      end)
      if not comment then
        return nil, "gh: Not Found (HTTP 404)"
      end
      comment.body = body.body

      return comment
    elseif endpoint:match("/events$") then
      forge.submitted = body
    elseif endpoint == "graphql" and body.query == publishers.registry.github.permissions then
      return { data = { repository = { viewerPermission = forge.permission or "WRITE", pullRequest = { locked = forge.locked or false, viewerDidAuthor = forge.author == "me" } } } }
    elseif endpoint == "graphql" then
      forge.next = forge.next + 1
      table.insert(forge.comments, { id = forge.next })

      return {
        data = {
          addPullRequestReviewThread = {
            thread = { id = "T" .. forge.next, comments = { nodes = { { id = "C" .. forge.next, databaseId = forge.next, url = "https://github.com/c/" .. forge.next } } } },
          },
        },
      }
    end
  end

  return forge
end

---@param forge table
local function stub(forge)
  publishers.run = function(cmd, stdin, callback)
    if cmd[1] == "git" then
      local out = git[table.concat(cmd, " ", 2)]
      table.insert(calls, { cmd = cmd, method = "GIT" })

      return callback({ code = out and 0 or 1, stdout = out or "", stderr = "" })
    end

    if cmd[2] == "pr" then
      table.insert(calls, { cmd = cmd, method = "GET" })

      return callback({
        code = 0,
        stdout = vim.json.encode({
          {
            id = "PR_7",
            number = forge.number,
            title = "Add the thing",
            url = "https://github.com/owner/repo/pull/7",
            author = { login = forge.author },
            isDraft = forge.draft,
            headRefName = "feature",
            baseRefName = "main",
            headRefOid = HEAD,
            baseRefOid = START,
          },
        }),
      })
    end

    local method = "GET"
    for i, arg in ipairs(cmd) do
      if arg == "--method" then
        method = cmd[i + 1]
      end
    end

    local body = stdin and vim.json.decode(stdin, { luanil = { object = true, array = true } })
    table.insert(calls, { cmd = cmd, method = method, endpoint = cmd[5], body = body })

    local value, err = forge.handle(cmd[5], method, body)
    if err then
      return callback({ code = 1, stdout = "", stderr = err })
    end

    callback({ code = 0, stdout = vim.json.encode(value or vim.empty_dict()), stderr = "" })
  end
end

---@param method string
---@param pattern string
---@return { cmd: string[], method: string, endpoint?: string, body?: table }[]
local function requests(method, pattern)
  return vim.tbl_filter(function(call)
    return call.method == method and call.endpoint ~= nil and call.endpoint:find(pattern) ~= nil
  end, calls)
end

--- GraphQL requests creating GitHub review threads.
---@return { cmd: string[], method: string, endpoint?: string, body?: table }[]
local function created()
  return vim.tbl_filter(function(call)
    return call.body ~= nil and call.body.query == publishers.registry.github.thread
  end, requests("GET", "^graphql$"))
end

---@param url string
local function remote(url)
  git = {
    ["symbolic-ref --short HEAD"] = "feature",
    ["config --get branch.feature.remote"] = "origin",
    ["config --get branch.feature.merge"] = "refs/heads/feature",
    ["remote"] = "origin",
    ["remote get-url origin"] = url,
    ["rev-parse HEAD"] = HEAD,
    [("merge-base %s %s"):format(START, HEAD)] = BASE,
  }
end

---@param prompts? string[]
---@param answers string[]
local function answer(answers, prompts)
  vim.ui.select = function(items, opts, callback)
    if prompts then
      table.insert(prompts, opts.prompt)
    end
    local want = table.remove(answers, 1)
    for _, item in ipairs(items) do
      if (opts.format_item and opts.format_item(item) or item) == want then
        return callback(item)
      end
    end
    callback(nil)
  end
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      calls, messages = {}, {}
      config.setup({ external = { summary = false } })
      H.repo({ ["a.lua"] = { "one" } })
      vim.notify = function(message)
        table.insert(messages, message)
      end
      remote("git@gitlab.example.com:group/sub/project.git")
    end,
    post_case = function()
      publishers.run = run
      vim.ui.select = select
      vim.notify = notify
      input.open = open
      config.setup()
    end,
  },
})

---@param fields table
---@return annotate.Annotation
local function add(fields)
  return store.add(vim.tbl_extend("force", { type = "report", text = "broken" }, fields))
end

local target = {
  id = 5,
  reference = "!5",
  head = HEAD,
  base = BASE,
  files = { { new_path = "a.lua", old_path = "a.lua", lines = publishers.parse_diff(PATCH) } },
  remote = { path = "group/sub/project" },
}

T["parse_diff maps added, removed and context lines with their other side"] = function()
  local lines = vim.tbl_map(function(side)
    return vim.tbl_map(function(line)
      return { hunk = line.hunk, old = line.old, new = line.new }
    end, side)
  end, publishers.parse_diff(PATCH))

  eq(lines.new, {
    [1] = { hunk = 1, old = 1 },
    [2] = { hunk = 1 },
    [3] = { hunk = 1 },
    [4] = { hunk = 1, old = 3 },
    [5] = { hunk = 1, old = 4 },
    [21] = { hunk = 2, old = 20 },
    [22] = { hunk = 2 },
    [23] = { hunk = 2, old = 21 },
  })
  eq(lines.old, {
    [1] = { hunk = 1, new = 1 },
    [2] = { hunk = 1 },
    [3] = { hunk = 1, new = 4 },
    [4] = { hunk = 1, new = 5 },
    [20] = { hunk = 2, new = 21 },
    [21] = { hunk = 2, new = 23 },
  })
end

T["parse_remote reads the host and the nested repository path"] = function()
  eq({ publishers.parse_remote("git@gitlab.example.com:group/sub/project.git") }, { "gitlab.example.com", "group/sub/project" })
  eq({ publishers.parse_remote("https://github.com/owner/repo.git") }, { "github.com", "owner/repo" })
  eq({ publishers.parse_remote("ssh://git@gitlab.example.com:2222/group/project") }, { "gitlab.example.com", "group/project" })
  eq({ publishers.parse_remote("https://user:token@gitlab.example.com/group/project/") }, { "gitlab.example.com", "group/project" })
end

T["plan positions lines inside the diff and falls back outside it"] = function()
  local plan = publishers.plan({
    add({ file = "a.lua", line = 2, line_end = 3 }),
    add({ file = "a.lua", line = 4 }),
    add({ file = "a.lua", line = 2, rev = BASE:sub(1, 11) }),
    add({ file = "a.lua", line = 10 }),
    add({ file = "a.lua", line = 3, line_end = 22 }),
    add({ file = "a.lua", line = 0 }),
    add({ file = "b.lua", line = 1 }),
    add({ file = "a.lua", line = 2, rev = "ddddddddddd" }),
    add({ line = 0 }),
  }, target)

  eq(
    vim.tbl_map(function(item)
      return { item.kind, item.side or false, item.new_line or false, item.old_line or false, item.fallback or false, item.in_diff or false }
    end, plan),
    {
      { "line", "new", 2, false, false, true },
      { "line", "new", 4, 3, false, true },
      { "line", "old", false, 2, false, true },
      { "file", false, false, false, true, true },
      { "file", false, false, false, true, true },
      { "file", false, false, false, false, true },
      { "file", false, false, false, true, false },
      { "file", false, false, false, true, true },
      { "repository", false, false, false, false, false },
    }
  )
  eq(plan[1].body, "broken")
end

T["routes and bodies per platform"] = function()
  local plan = publishers.plan({
    add({ file = "a.lua", line = 2 }),
    add({ file = "a.lua", line = 10 }),
    add({ file = "a.lua", line = 0 }),
    add({ file = "b.lua", line = 1 }),
    add({ line = 0 }),
  }, target)

  local function route(publisher)
    return vim.tbl_map(function(item)
      return { publisher.route(item) }
    end, plan)
  end

  eq(route(publishers.registry.gitlab), {
    { "inline", "broken" },
    { "general", "`a.lua:10`\n\nbroken" },
    { "general", "`a.lua`\n\nbroken" },
    { "general", "`b.lua:1`\n\nbroken" },
    { "general", "broken" },
  })
  eq(route(publishers.registry.github), {
    { "inline", "broken" },
    { "file", "`a.lua:10`\n\nbroken" },
    { "file", "broken" },
    { "conversation", "`b.lua:1`\n\nbroken" },
    { "conversation", "broken" },
  })
end

T["rewrites in the diff become suggestions covering their lines"] = function()
  local text = "```lua\nX\nY\n```\nshorter"
  local plan = publishers.plan({
    add({ type = "rewrite", file = "a.lua", line = 2, line_end = 3, text = text }),
    add({ type = "rewrite", file = "a.lua", line = 4, text = text }),
    add({ type = "rewrite", file = "a.lua", line = 10, text = text }),
    add({ type = "rewrite", file = "a.lua", line = 2, rev = BASE:sub(1, 11), text = text }),
  }, target)

  local function route(publisher)
    return vim.tbl_map(function(item)
      return { publisher.route(item) }
    end, plan)
  end

  eq(route(publishers.registry.github), {
    { "suggestion", "```suggestion\nX\nY\n```\nshorter" },
    { "suggestion", "```suggestion\nX\nY\n```\nshorter" },
    { "file", "`a.lua:10`\n\n```lua\nX\nY\n```\nshorter" },
    { "inline", "```lua\nX\nY\n```\nshorter" },
  })
  eq(route(publishers.registry.gitlab), {
    { "suggestion", "```suggestion:-0+1\nX\nY\n```\nshorter" },
    { "suggestion", "```suggestion:-0+0\nX\nY\n```\nshorter" },
    { "general", "`a.lua:10`\n\n```lua\nX\nY\n```\nshorter" },
    { "inline", "```lua\nX\nY\n```\nshorter" },
  })
end

T["a rewrite outside the diff posts a plain block and is counted"] = function()
  remote("git@github.com:owner/repo.git")
  stub(github())
  config.setup({ external = { summary = true } })
  add({ type = "rewrite", file = "a.lua", line = 2, line_end = 3, text = "```lua\nX\n```" })
  add({ type = "rewrite", file = "a.lua", line = 10, text = "```lua\nX\n```" })
  local prompts = {}
  answer({ "Proceed" }, prompts)

  publishers.publish()

  local threads = created()
  eq({ threads[1].body.variables.line, threads[1].body.variables.startLine, threads[1].body.variables.body }, { 3, 2, "```suggestion\nX\n```" })
  eq(threads[2].body.variables.subjectType, "FILE")
  eq(prompts[1]:find("- To post: 2 (1 suggestion, 1 outside the diff, 1 rewrite without a suggestion)", 1, true) ~= nil, true)
  eq(prompts[1]:find("- Destination: suggestion", 1, true) ~= nil, true)
  eq(messages[#messages], "#7 Add the thing: 2 staged, 0 updated, 0 skipped as already posted, 1 fell back to general comments, 1 rewrite without a suggestion.")
end

T["bodies carry no type label unless the legend is on"] = function()
  stub(gitlab())
  add({ file = "a.lua", line = 2 })

  publishers.publish()

  eq(
    vim.tbl_map(function(call)
      return call.body.note
    end, requests("POST", "draft_notes$")),
    { "broken" }
  )
end

T["the legend labels the bodies and lists the external prompts of the used types once per target"] = function()
  local forge = gitlab()
  stub(forge)
  add({ file = "a.lua", line = 2 })
  add({ file = "a.lua", line = 4, type = "discuss", text = "why?" })
  local legend = table.concat({
    config.options.external.legend_prompt,
    "",
    "- **[DISCUSS] (here)**: " .. config.type("discuss").external.prompt,
    "- **[REPORT] (here)**: " .. config.type("report").external.prompt,
  }, "\n")

  publishers.publish({ legend = true })

  eq(
    vim.tbl_map(function(call)
      return call.body.note
    end, requests("POST", "draft_notes$")),
    { legend, "**[REPORT] (here)**\n\nbroken", "**[DISCUSS] (here)**\n\nwhy?" }
  )
  eq(legend:find(config.type("report").export.prompt, 1, true), nil)
  store.load(true)
  eq({ store.legend.posted[1].target, store.legend.posted[1].state, store.legend.posted[1].id }, { 5, "draft", 101 })

  publishers.publish({ legend = true })

  eq(#requests("POST", "draft_notes$"), 3)
  eq(messages[#messages], "Every annotation is already posted to !5 Add the thing, 3 notes skipped.")
end

T["the legend prompt can be a callback building on its default"] = function()
  local forge = gitlab()
  stub(forge)
  local default = config.options.external.legend_prompt
  local received
  config.setup({
    external = {
      summary = false,
      legend_prompt = function(prompt, sections)
        received = { prompt, #sections }

        return "PREFIX " .. prompt
      end,
    },
  })
  add({ file = "a.lua", line = 2 })

  publishers.publish({ legend = true })

  eq(received, { default, 1 })
  eq(vim.split(requests("POST", "draft_notes$")[1].body.note, "\n")[1], "PREFIX " .. default)
end

T["external.legend turns the legend on and GitHub queues it as its own conversation comment"] = function()
  remote("git@github.com:owner/repo.git")
  local forge = github()
  stub(forge)
  config.setup({ external = { summary = false, legend = true, legend_prompt = "KINDS" } })
  add({ line = 0, text = "overall" })

  publishers.publish()

  eq(#requests("POST", "/comments$"), 0)
  store.load(true)
  eq(store.legend.posted[1].state, "queued")

  publishers.publish({ publish = true, verdict = "comment", note = "" })

  eq(
    vim.tbl_map(function(comment)
      return comment.body
    end, forge.conversation),
    { "KINDS\n\n- **[REPORT] (here)**: " .. config.type("report").external.prompt, "**[REPORT] (here)**\n\noverall" }
  )
  eq(#requests("POST", "/reviews$"), 0)
  store.load(true)
  eq({ store.legend.posted[1].state, store.legend.posted[1].issue_comment_id }, { "published", 201 })
end

T["the summary shows the legend and its text"] = function()
  stub(gitlab())
  config.setup({ external = { legend = true, legend_prompt = "KINDS" } })
  add({ file = "a.lua", line = 2 })
  local prompts = {}
  answer({ "Cancel" }, prompts)

  publishers.publish()

  eq(prompts[1]:find(
    table.concat({
      "- Legend: on, comments are labelled with their type",
      "",
      "## Legend",
      "",
      "- Destination: general comment",
      "- Status: new",
      "",
      "KINDS",
      "",
      "- **[REPORT] (here)**: " .. config.type("report").external.prompt,
    }, "\n"),
    1,
    true
  ) ~= nil, true)
  eq(prompts[1]:find("**[REPORT] (here)**\n\nbroken", 1, true) ~= nil, true)
end

T["GitLab entries record the forge ids and the posted body"] = function()
  stub(gitlab())
  local annotation = add({ file = "a.lua", line = 2 })

  publishers.publish()
  store.load(true)
  local entry = store.get(annotation.id).posted[1]
  eq({ entry.id, entry.draft_id, entry.mr_id, entry.iid, entry.project_id, entry.body, entry.hash }, { 101, 101, 9005, 5, 42, "broken", publishers.sha1("broken") })

  publishers.publish({ publish = true, verdict = "comment", note = "" })
  store.load(true)
  entry = store.get(annotation.id).posted[1]
  eq({ entry.state, entry.note_id, entry.discussion_id }, { "published", 1101, "d1101" })
end

T["a changed draft is updated in place"] = function()
  local forge = gitlab()
  stub(forge)
  local annotation = add({ file = "a.lua", line = 2 })
  publishers.publish()
  store.update(annotation.id, { text = "really broken" })
  config.setup({ external = { summary = true } })
  local prompts = {}
  answer({ "Proceed" }, prompts)

  publishers.publish()

  eq(#requests("POST", "draft_notes$"), 1)
  eq(requests("PUT", "draft_notes/101$")[1].body, { note = "really broken" })
  eq(forge.drafts[1].note, "really broken")
  eq(prompts[1]:find("- Status: update, draft on !5, line 1: `broken` -> `really broken`", 1, true) ~= nil, true)
  eq(prompts[1]:find("- To post: 1 (1 update)", 1, true) ~= nil, true)
  store.load(true)
  eq({ #store.get(annotation.id).posted, store.get(annotation.id).posted[1].hash }, { 1, publishers.sha1("really broken") })
  eq(messages[#messages], "!5 Add the thing: 0 staged, 1 updated, 0 skipped as already posted, 0 fell back to general comments.")
end

T["a changed published note is updated, and posted again when it was deleted"] = function()
  local forge = gitlab()
  stub(forge)
  local annotation = add({ file = "a.lua", line = 2 })
  publishers.publish({ publish = true, verdict = "comment", note = "" })

  store.update(annotation.id, { text = "edited" })
  publishers.publish()

  eq(requests("PUT", "notes/1101$")[1].body, { body = "edited" })
  eq(forge.notes[1].body, "edited")

  forge.notes = {}
  store.update(annotation.id, { text = "edited again" })
  publishers.publish()

  eq(#requests("POST", "draft_notes$"), 2)
  store.load(true)
  local posted = store.get(annotation.id).posted
  eq({ #posted, posted[1].state, posted[1].body }, { 1, "draft", "edited again" })
end

T["GitHub records the forge ids and updates changed review and conversation comments"] = function()
  remote("git@github.com:owner/repo.git")
  local forge = github()
  stub(forge)
  local inline = add({ file = "a.lua", line = 2 })
  local overall = add({ line = 0, text = "overall" })
  add({ line = 0, type = "discuss", text = "kept" })

  publishers.publish({ publish = true, verdict = "comment", note = "" })
  store.load(true)
  local entry = store.get(inline.id).posted[1]
  eq(
    { entry.id, entry.comment_id, entry.comment_node_id, entry.thread_node_id, entry.review_id, entry.review_node_id, entry.pr_node_id },
    { 202, 202, "C202", "T202", 201, "R201", "PR_7" }
  )
  entry = store.get(overall.id).posted[1]
  eq({ entry.state, entry.issue_comment_id, entry.issue_comment_node_id, entry.comment_url }, { "published", 203, "IC203", "https://github.com/i/203" })

  store.update(inline.id, { text = "fixed wording" })
  store.update(overall.id, { text = "overall, revised" })
  publishers.publish()

  eq(requests("PATCH", "pulls/comments/202$")[1].body, { body = "fixed wording" })
  eq(requests("PATCH", "issues/comments/203$")[1].body, { body = "overall, revised" })
  eq(forge.conversation[1].body, "overall, revised")
  eq(#created(), 1)
  eq(#requests("POST", "/comments$"), 2)
end

T["refuses when HEAD is not the head of the merge request"] = function()
  stub(gitlab())
  git["rev-parse HEAD"] = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
  add({ file = "a.lua", line = 2 })

  publishers.publish()

  eq(#requests("POST", ""), 0)
  eq(messages[#messages]:find("lines may not match the diff", 1, true) ~= nil, true)
end

T["the upstream remote wins over origin"] = function()
  stub(gitlab())
  git["config --get branch.feature.remote"] = "upstream"
  git["remote"] = "origin\nupstream"
  git["remote get-url upstream"] = "git@gitlab.example.com:group/sub/project.git"
  git["remote get-url origin"] = "git@github.com:owner/repo.git"
  answer({})
  add({ file = "a.lua", line = 2 })

  publishers.publish()

  eq(#requests("POST", "draft_notes$"), 1)
end

T["without an upstream it asks between several remotes once per repository"] = function()
  stub(gitlab())
  git["config --get branch.feature.remote"] = nil
  git["remote"] = "origin\nupstream"
  git["remote get-url upstream"] = "git@gitlab.example.com:group/sub/project.git"
  local prompts = {}
  answer({ "upstream  git@gitlab.example.com:group/sub/project.git" }, prompts)
  add({ file = "a.lua", line = 2 })

  publishers.publish()
  publishers.publish()

  eq(prompts, { "annotate: remote to publish to" })
  eq(#requests("POST", "draft_notes$"), 1)
end

T["without an upstream a single remote is used without asking"] = function()
  stub(gitlab())
  git["config --get branch.feature.remote"] = nil
  local prompts = {}
  answer({}, prompts)
  add({ file = "a.lua", line = 2 })

  publishers.publish()

  eq(prompts, {})
  eq(#requests("POST", "draft_notes$"), 1)
end

T["GitLab staging creates positioned and general drafts without publishing them"] = function()
  stub(gitlab())
  local inline = add({ file = "a.lua", line = 4 })
  local outside = add({ file = "a.lua", line = 10 })

  publishers.publish()

  local drafts = requests("POST", "draft_notes$")
  eq(drafts[1].endpoint, "projects/group%2fsub%2fproject/merge_requests/5/draft_notes")
  eq(drafts[1].body, {
    note = "broken",
    position = { position_type = "text", base_sha = BASE, start_sha = START, head_sha = HEAD, new_path = "a.lua", old_path = "a.lua", new_line = 4, old_line = 3 },
  })
  eq(drafts[2].body, { note = "`a.lua:10`\n\nbroken" })
  eq(#requests("POST", "bulk_publish"), 0)

  store.load(true)
  local entry = store.get(inline.id).posted[1]
  eq({ entry.platform, entry.project, entry.target, entry.reference, entry.branch, entry.target_branch, entry.title, entry.state, entry.id }, {
    "gitlab",
    "group/sub/project",
    5,
    "!5",
    "feature",
    "main",
    "Add the thing",
    "draft",
    101,
  })
  eq(entry.url, "https://gitlab.example.com/group/sub/project/-/merge_requests/5")
  eq(store.get(outside.id).posted[1].id, 102)
  eq(messages[#messages], "!5 Add the thing: 2 staged, 0 updated, 0 skipped as already posted, 1 fell back to general comments.")
end

T["GitLab submit publishes the drafts, posts the note and approves"] = function()
  local forge = gitlab()
  stub(forge)
  local annotation = add({ file = "a.lua", line = 2 })

  publishers.publish({ publish = true, verdict = "approve", note = "Looks good." })

  eq(#requests("POST", "bulk_publish$"), 1)
  eq(requests("POST", "/notes$")[1].body, { body = "Looks good." })
  eq(forge.approved, HEAD)
  store.load(true)
  local entry = store.get(annotation.id).posted[1]
  eq(entry.state, "published")
  eq(entry.comment_url, "https://gitlab.example.com/group/sub/project/-/merge_requests/5#note_1101")
end

--- Answers the verdict chooser with `want`, returning the labels it offered, or nil when it was not asked.
---@param want string
---@return { offered?: string[] }
local function verdict(want)
  local asked = {}
  vim.ui.select = function(items, opts, callback)
    local format = opts.format_item or tostring
    asked.offered = vim.tbl_map(format, items)
    for _, item in ipairs(items) do
      if format(item) == want then
        return callback(item)
      end
    end
    callback(nil)
  end

  return asked
end

T["an empty note posts nothing"] = function()
  stub(gitlab())
  verdict("Comment")
  input.open = function(opts, callback)
    eq(opts.title, "Review note")
    callback(nil, "")
  end
  add({ file = "a.lua", line = 2 })

  publishers.publish({ publish = true })

  eq(#requests("POST", "bulk_publish$"), 1)
  eq(#requests("POST", "/notes$"), 0)
  eq(#requests("POST", "/approve$"), 0)
end

T["GitLab offers Approve while the user can approve"] = function()
  stub(gitlab())
  local asked = verdict("Approve")
  add({ file = "a.lua", line = 2 })

  publishers.publish({ publish = true, note = "" })

  eq(asked.offered, { "Comment", "Approve", "Request changes" })
  eq(#requests("POST", "/approve$"), 1)
end

T["GitLab offers Unapprove once the user has approved"] = function()
  local forge = gitlab()
  forge.approvals = { user_can_approve = false, user_has_approved = true }
  forge.approved = HEAD
  stub(forge)
  local asked = verdict("Unapprove")
  add({ file = "a.lua", line = 2 })

  publishers.publish({ publish = true, note = "" })

  eq(asked.offered, { "Comment", "Unapprove", "Request changes" })
  eq(forge.approved, false)
end

T["GitLab only comments without asking when the user can not approve and already requested changes"] = function()
  local forge = gitlab()
  forge.approvals = { user_can_approve = false, user_has_approved = false }
  forge.review_state = "REQUESTED_CHANGES"
  stub(forge)
  config.setup({ external = { summary = true } })
  local asked = verdict("Proceed")
  add({ file = "a.lua", line = 2 })

  publishers.publish({ publish = true, note = "" })

  eq(asked.offered, { "Proceed", "Cancel" })
  eq(#requests("POST", "bulk_publish$"), 1)
  eq(#requests("POST", "/approve$"), 0)
end

T["GitLab requests changes through GraphQL"] = function()
  local forge = gitlab()
  stub(forge)
  verdict("Request changes")
  add({ file = "a.lua", line = 2 })

  publishers.publish({ publish = true, note = "Please fix." })

  eq(#requests("POST", "bulk_publish$"), 1)
  eq(forge.review_state, "REQUESTED_CHANGES")
  eq(#requests("POST", "/approve$"), 0)
end

T["GitLab asks to add the user as a reviewer before requesting changes"] = function()
  local forge = gitlab()
  forge.reviewer = false
  stub(forge)
  local prompts = {}
  answer({ "Request changes", "No" }, prompts)
  add({ file = "a.lua", line = 2 })

  publishers.publish({ publish = true, note = "" })

  eq(prompts[2], "annotate: Requesting changes needs you as a reviewer, add yourself as a reviewer of !5?")
  eq(messages[#messages], "Submitting the review was cancelled.")
  eq({ forge.reviewer, #requests("POST", "draft_notes$") }, { false, 0 })

  answer({ "Request changes", "Yes" })
  publishers.publish({ publish = true, note = "" })

  eq({ forge.reviewer, forge.review_state }, { "me", "REQUESTED_CHANGES" })
  eq(#requests("POST", "bulk_publish$"), 1)
end

T["GitLab refuses to submit when the user can not comment"] = function()
  local forge = gitlab()
  forge.locked = true
  stub(forge)
  add({ file = "a.lua", line = 2 })

  publishers.publish({ publish = true, verdict = "comment", note = "" })

  eq(messages[#messages], "annotate: you can not comment on !5: its discussion is locked")
  eq(#requests("POST", "draft_notes$"), 0)
end

T["GitHub refuses to submit on a locked pull request without write access"] = function()
  remote("git@github.com:owner/repo.git")
  local forge = github()
  forge.locked = true
  forge.permission = "READ"
  stub(forge)
  add({ file = "a.lua", line = 2 })

  publishers.publish({ publish = true, verdict = "comment", note = "" })

  eq(messages[#messages], "annotate: you can not comment on #7: its conversation is locked to collaborators")
  eq(forge.submitted, nil)
end

T["GitHub lets collaborators review a locked pull request"] = function()
  remote("git@github.com:owner/repo.git")
  local forge = github()
  forge.locked = true
  stub(forge)
  local asked = verdict("Approve")
  add({ file = "a.lua", line = 2 })

  publishers.publish({ publish = true, note = "" })

  eq(asked.offered, { "Comment", "Approve", "Request changes" })
  eq(forge.submitted.event, "APPROVE")
end

T["GitHub offers only Comment on a pull request the user authored"] = function()
  remote("git@github.com:owner/repo.git")
  local forge = github()
  forge.author = "me"
  forge.draft = true
  stub(forge)
  config.setup({ external = { summary = true } })
  local prompts = {}
  answer({ "Proceed" }, prompts)
  add({ file = "a.lua", line = 2 })

  publishers.publish({ publish = true, note = "" })

  eq(#prompts, 1)
  eq(prompts[1]:find("- Verdict: Comment (approving is not available: you authored this pull request)", 1, true) ~= nil, true)
  eq(prompts[1]:find("- Draft: yes, comments are allowed but the pull request is not ready", 1, true) ~= nil, true)
  eq(forge.submitted.event, "COMMENT")
end

T["GitHub offers every verdict on someone else's pull request"] = function()
  remote("git@github.com:owner/repo.git")
  local forge = github()
  stub(forge)
  local asked = verdict("Approve")
  add({ file = "a.lua", line = 2 })

  publishers.publish({ publish = true, note = "" })

  eq(asked.offered, { "Comment", "Approve", "Request changes" })
  eq(forge.submitted.event, "APPROVE")
end

T["a verdict the target does not allow is refused"] = function()
  remote("git@github.com:owner/repo.git")
  local forge = github()
  forge.author = "me"
  stub(forge)
  add({ file = "a.lua", line = 2 })

  publishers.publish({ publish = true, verdict = "approve", note = "" })

  eq(messages[#messages], "annotate: the approve verdict is not available on this pull request: approving is not available: you authored this pull request")
  eq(forge.submitted, nil)
end

T["submit asks summary, verdict and note in order before posting anything"] = function()
  remote("git@github.com:owner/repo.git")
  local forge = github()
  stub(forge)
  config.setup({ external = { summary = true } })
  local order = {}
  local stubbed = publishers.run
  publishers.run = function(cmd, stdin, callback)
    for _, arg in ipairs(cmd) do
      if arg == "POST" or arg == "PATCH" or arg == "PUT" then
        table.insert(order, "post")
        break
      end
    end
    stubbed(cmd, stdin, callback)
  end
  vim.ui.select = function(items, opts, callback)
    if opts.prompt == "annotate: submit the review as" then
      table.insert(order, "verdict")
      return callback(items[2])
    end
    table.insert(order, "summary")
    callback(items[1])
  end
  input.open = function(opts, callback)
    table.insert(order, "note")
    eq(opts.title, "Review note")
    callback(nil, "Thanks.")
  end
  add({ file = "a.lua", line = 2 })

  publishers.publish({ publish = true })

  eq(vim.list_slice(order, 1, 4), { "summary", "verdict", "note", "post" })
  eq(forge.submitted, { event = "APPROVE", body = "Thanks." })
end

T["cancelling the review note cancels the submit"] = function()
  stub(gitlab())
  answer({ "Comment" })
  input.open = function(_, callback)
    callback(nil, nil)
  end
  add({ file = "a.lua", line = 2 })

  publishers.publish({ publish = true })

  eq(#requests("POST", ""), 0)
  eq(messages[#messages], "Submitting the review was cancelled.")
end

T["staging asks neither the verdict nor the note"] = function()
  stub(gitlab())
  local asked = {}
  vim.ui.select = function(_, opts)
    table.insert(asked, opts.prompt)
  end
  input.open = function()
    table.insert(asked, "note")
  end
  add({ file = "a.lua", line = 2 })

  publishers.publish()

  eq(asked, {})
  eq(#requests("POST", "draft_notes$"), 1)
end

T["cancelling the verdict posts nothing"] = function()
  stub(gitlab())
  answer({})
  add({ file = "a.lua", line = 2 })

  publishers.publish({ publish = true })

  eq(#requests("POST", ""), 0)
end

T["a submit after staging publishes the drafts without posting them again"] = function()
  stub(gitlab())
  local annotation = add({ file = "a.lua", line = 2 })

  publishers.publish()
  publishers.publish({ publish = true, verdict = "comment", note = "" })

  eq(#requests("POST", "draft_notes$"), 1)
  eq(#requests("POST", "bulk_publish$"), 1)
  store.load(true)
  eq(#store.get(annotation.id).posted, 1)
  eq(store.get(annotation.id).posted[1].state, "published")
  eq(messages[#messages]:find("0 submitted, 0 updated, 1 skipped as already posted", 1, true) ~= nil, true)
end

T["notes already posted to the same target are skipped"] = function()
  stub(gitlab())
  add({ file = "a.lua", line = 2 })

  publishers.publish()
  publishers.publish()

  eq(#requests("POST", "draft_notes$"), 1)
  eq(messages[#messages], "Every annotation is already posted to !5 Add the thing, 1 note skipped.")
end

T["notes are posted again to another target"] = function()
  local forge = gitlab()
  stub(forge)
  local annotation = add({ file = "a.lua", line = 2 })

  publishers.publish()
  forge.iid = 6
  publishers.publish()

  eq(#requests("POST", "draft_notes$"), 2)
  store.load(true)
  eq(
    vim.tbl_map(function(entry)
      return entry.target
    end, store.get(annotation.id).posted),
    { 5, 6 }
  )
end

T["a recorded draft deleted on the forge is posted again"] = function()
  local forge = gitlab()
  stub(forge)
  local annotation = add({ file = "a.lua", line = 2 })

  publishers.publish()
  forge.drafts = {}
  publishers.publish()

  eq(#requests("POST", "draft_notes$"), 2)
  store.load(true)
  eq(
    vim.tbl_map(function(entry)
      return entry.id
    end, store.get(annotation.id).posted),
    { 102 }
  )
end

T["GitHub staging creates a pending review with threads and no event"] = function()
  remote("git@github.com:owner/repo.git")
  local forge = github()
  stub(forge)
  local inline = add({ file = "a.lua", line = 2, line_end = 3 })
  add({ file = "a.lua", line = 0 })
  add({ line = 0, text = "overall" })

  publishers.publish()

  local reviews = requests("POST", "/reviews$")
  eq(#reviews, 1)
  eq(reviews[1].body, { commit_id = HEAD })
  eq(#requests("POST", "/comments$"), 0)
  local threads = created()
  eq(threads[1].body.variables, { review = "R201", path = "a.lua", body = "broken", line = 3, side = "RIGHT", startLine = 2, startSide = "RIGHT" })
  eq(threads[2].body.variables, { review = "R201", path = "a.lua", body = "broken", subjectType = "FILE" })
  eq(#requests("POST", "/events$"), 0)
  store.load(true)
  eq({ store.get(inline.id).posted[1].id, store.get(inline.id).posted[1].comment_url }, { 202, "https://github.com/c/202" })
  local queued = vim.iter(store.all()):find(function(annotation)
    return annotation.text == "overall"
  end)
  eq(queued.posted[1].state, "queued")
end

T["queued notes show in the summary and are posted one by one on submit"] = function()
  remote("git@github.com:owner/repo.git")
  local forge = github()
  stub(forge)
  config.setup({ external = { summary = true } })
  add({ line = 0, text = "first" })
  add({ file = "b.lua", line = 1, text = "second" })
  local prompts = {}
  answer({ "Proceed" }, prompts)

  publishers.publish()

  eq(prompts[1]:find("- Destination: conversation comment\n- Status: new, queued, posted on submit", 1, true) ~= nil, true)
  eq(prompts[1]:find("- Destination: conversation comment (outside the diff)", 1, true) ~= nil, true)
  eq(#requests("POST", "/reviews$"), 0)

  publishers.publish({ publish = true, verdict = "comment", note = "", force = true })

  eq(
    vim.tbl_map(function(comment)
      return comment.body
    end, forge.conversation),
    { "first", "`b.lua:1`\n\nsecond" }
  )

  publishers.publish({ publish = true, verdict = "comment", note = "", force = true })

  eq(#forge.conversation, 2)
end

T["GitHub submit finalizes the pending review with the verdict and note"] = function()
  remote("git@github.com:owner/repo.git")
  local forge = github()
  stub(forge)
  local staged = add({ file = "a.lua", line = 2 })

  publishers.publish()
  local added = add({ file = "a.lua", line = 4 })
  answer({ "Request changes" })
  input.open = function(_, callback)
    callback(nil, "Please fix.")
  end
  publishers.publish({ publish = true })

  eq(#requests("POST", "/reviews$"), 1)
  eq(#created(), 2)
  eq(forge.submitted, { event = "REQUEST_CHANGES", body = "Please fix." })
  store.load(true)
  eq({ store.get(staged.id).posted[1].state, store.get(added.id).posted[1].state }, { "published", "published" })
end

T["GitHub submit without anything staged creates the review with the event"] = function()
  remote("git@github.com:owner/repo.git")
  local forge = github()
  stub(forge)

  publishers.publish({ publish = true, verdict = "approve", note = "" })

  eq(requests("POST", "/reviews$")[1].body, { commit_id = HEAD, event = "APPROVE" })
end

T["the summary lists the target, each destination and the totals"] = function()
  stub(gitlab())
  config.setup({ external = { summary = true } })
  add({ file = "a.lua", line = 4 })
  add({ file = "a.lua", line = 10, type = "discuss" })
  publishers.publish({ force = true })
  add({ line = 0, type = "discuss", text = "overall" })
  local prompts = {}
  answer({ "Cancel" }, prompts)

  local before = #requests("POST", "")
  publishers.publish()

  eq(#requests("POST", ""), before)
  eq(
    prompts[1],
    table.concat({
      "Stage drafts",
      "",
      "# Stage drafts",
      "",
      "## Target",
      "",
      "- Platform: GitLab",
      "- Merge request: !5 Add the thing",
      "- Branches: `feature` -> `main`",
      "- URL: https://gitlab.example.com/group/sub/project/-/merge_requests/5",
      "- Head: `aaaaaaaaaaa` (matches local HEAD)",
      "",
      "## Summary",
      "",
      "- To post: 1",
      "- Skipped: 2 (already draft or published)",
      "- Legend: off",
      "",
      "## [DISCUSS] (here)",
      "",
      "### repository",
      "",
      "- Destination: general comment",
      "- Status: new",
      "",
      "overall",
      "",
      "### `a.lua:10`",
      "",
      "- Status: skipped, draft on !5 https://gitlab.example.com/group/sub/project/-/merge_requests/5",
      "",
      "---",
      "",
      "## [REPORT] (here)",
      "",
      "### `a.lua:4`",
      "",
      "- Status: skipped, draft on !5 https://gitlab.example.com/group/sub/project/-/merge_requests/5",
    }, "\n")
  )
end

T["proceeding with the summary posts exactly the planned bodies"] = function()
  stub(gitlab())
  config.setup({ external = { summary = true } })
  add({ file = "a.lua", line = 4 })
  add({ file = "b.lua", line = 1 })
  local prompts = {}
  answer({ "Proceed" }, prompts)

  publishers.publish()

  local drafts = requests("POST", "draft_notes$")
  eq(#drafts, 2)
  for _, draft in ipairs(drafts) do
    eq(prompts[1]:find(draft.body.note, 1, true) ~= nil, true)
  end
  eq(prompts[1]:find("- Destination: inline, new side", 1, true) ~= nil, true)
  eq(prompts[1]:find("- Destination: general comment (outside the diff)", 1, true) ~= nil, true)
  eq(prompts[1]:find("- To post: 2 (1 outside the diff)", 1, true) ~= nil, true)
end

T["a failing CLI reports its stderr and records nothing"] = function()
  stub(gitlab())
  local stubbed = publishers.run
  publishers.run = function(cmd, stdin, callback)
    if cmd[5] and cmd[5]:match("draft_notes$") and stdin then
      return callback({ code = 1, stdout = "", stderr = "403 Forbidden" })
    end
    stubbed(cmd, stdin, callback)
  end
  local annotation = add({ file = "a.lua", line = 2 })

  publishers.publish()

  eq(messages[#messages]:find("403 Forbidden", 1, true) ~= nil, true)
  store.load(true)
  eq(store.get(annotation.id).posted, nil)
end

T["parse_diff records each line's position on both sides"] = function()
  local lines = publishers.parse_diff(PATCH)

  eq(lines.new[2], { hunk = 1, type = "new", old_pos = 3, new_pos = 2 })
  eq(lines.new[4], { hunk = 1, old = 3, old_pos = 3, new_pos = 4 })
  eq(lines.old[2], { hunk = 1, type = "old", old_pos = 2, new_pos = 2 })
end

T["GitLab ranges carry a line_range from the first to the last line"] = function()
  stub(gitlab())
  add({ file = "a.lua", line = 2, line_end = 4 })
  add({ file = "a.lua", line = 4 })

  publishers.publish()

  local drafts = requests("POST", "draft_notes$")
  local code = publishers.sha1("a.lua")
  eq(drafts[1].body.position.line_range, {
    start = { line_code = code .. "_3_2", type = "new", new_line = 2 },
    ["end"] = { line_code = code .. "_3_4", old_line = 3, new_line = 4 },
  })
  eq(drafts[2].body.position.line_range, nil)
end

T["sha1 matches the reference digests"] = function()
  eq(publishers.sha1(""), "da39a3ee5e6b4b0d3255bfef95601890afd80709")
  eq(publishers.sha1("abc"), "a9993e364706816aba3e25717850c26c9cd0d89d")
end

return T
