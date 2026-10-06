local H = dofile("tests/helpers.lua")
local eq = MiniTest.expect.equality

local api = require("annotate.api")
local input = require("annotate.input")
local store = require("annotate.store")

local open = input.open
local select = vim.ui.select
local notify = vim.notify
local opened

--- Answers vim.ui.select with the first item whose text contains each wanted string in turn, returning the prompts it was asked.
---@param wanted string[]
---@return string[]
local function answer(wanted)
  local prompts = {}
  vim.ui.select = function(items, opts, callback)
    table.insert(prompts, opts.prompt)
    local want = table.remove(wanted, 1)
    for _, item in ipairs(items) do
      if (opts.format_item and opts.format_item(item) or item):find(want, 1, true) then
        return callback(item)
      end
    end
    callback(nil)
  end

  return prompts
end

---@return string[]
local function texts()
  return vim.tbl_map(function(annotation)
    return annotation.text
  end, store.load(true))
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      opened = nil
      input.open = function(opts)
        opened = opts
      end
      H.repo({ ["a.lua"] = { "one", "two" } })
      vim.cmd.edit("a.lua")
    end,
    post_case = function()
      package.loaded.snacks = nil
      vim.cmd.stopinsert()
      input.open = open
      vim.ui.select = select
      vim.notify = notify
      require("annotate").setup()
      vim.cmd("silent! %bwipeout!")
    end,
  },
})

T["starts the input on the first type"] = function()
  require("annotate").setup()

  api.add()

  eq(opened.type, "apply")
end

T["starts the input on default_type"] = function()
  require("annotate").setup({ default_type = "report" })

  api.add()

  eq(opened.type, "report")
end

T["an explicit type wins over default_type"] = function()
  require("annotate").setup({ default_type = "report" })

  api.add_file({ type = "discuss" })

  eq(opened.type, "discuss")
end

T["add_with_type stores the chosen type on the visual selection"] = function()
  require("annotate").setup()
  local prompts = answer({ "Report" })
  input.open = function(opts, callback)
    opened = opts
    callback(opts.type, "chosen")
  end

  vim.api.nvim_feedkeys("Vj", "nx!", false)
  eq(vim.fn.mode(), "V")
  api.add_with_type()

  eq(prompts, { "Annotation type" })
  eq(opened.type, "report")
  local added = store.load(true)[1]
  eq({ added.type, added.line, added.line_end, added.text }, { "report", 1, 2, "chosen" })
end

T["annotates a file outside a git repository"] = function()
  require("annotate").setup()
  vim.cmd("silent! %bwipeout!")
  local dir = H.dir({ ["b.lua"] = { "one", "two" } })
  vim.cmd.edit("b.lua")
  input.open = function(opts, callback)
    callback(opts.type, "outside")
  end

  api.add()

  eq(vim.startswith(store.path(), require("annotate.config").options.store.dir), true)
  eq(require("annotate.git").workspace(), dir)
  local added = store.load(true)[1]
  eq({ added.file, added.line, added.text }, { "b.lua", 1, "outside" })
end

T["add_file_with_type stores the chosen type on the whole file"] = function()
  require("annotate").setup()
  local prompts = answer({ "Discuss" })
  input.open = function(opts, callback)
    opened = opts
    callback(opts.type, "file note")
  end

  api.add_file_with_type()

  eq(prompts, { "Annotation type" })
  local added = store.load(true)[1]
  eq({ added.type, added.line, added.text }, { "discuss", 0, "file note" })
end

T["add_repository_with_type stores the chosen type attached to no file"] = function()
  require("annotate").setup()
  local prompts = answer({ "Keep" })
  input.open = function(opts, callback)
    callback(opts.type, "repo note")
  end

  api.add_repository_with_type()

  eq(prompts, { "Annotation type" })
  local added = store.load(true)[1]
  eq({ added.type, added.file, added.line, added.text }, { "keep", nil, 0, "repo note" })
end

T["add_with_type does nothing when the chooser is cancelled"] = function()
  require("annotate").setup()
  answer({ "missing" })

  api.add_with_type()

  eq(opened, nil)
  eq(#store.load(true), 0)
end

T["edit chooses between overlapping annotations"] = function()
  require("annotate").setup()
  store.add({ file = "a.lua", line = 1, line_end = 2, type = "report", text = "range" })
  local single = store.add({ file = "a.lua", line = 1, type = "discuss", text = "single" })
  local prompts = answer({ "Discuss: single (a.lua:1)" })
  local edit
  input.open = function(opts, callback)
    edit = opts
    callback("keep", "changed")
  end

  api.edit()

  eq(prompts, { "Annotations" })
  eq(edit, { type = "discuss", text = "single" })
  eq(store.get(single.id).text, "changed")
  eq(texts(), { "range", "changed" })
end

T["delete removes only the chosen overlapping annotation"] = function()
  require("annotate").setup({ confirm_delete = false })
  store.add({ file = "a.lua", line = 1, line_end = 2, type = "report", text = "range" })
  store.add({ file = "a.lua", line = 1, type = "discuss", text = "single" })
  answer({ "Report: range (a.lua:1-2)" })

  api.delete()

  eq(texts(), { "single" })
end

T["delete removes all of the overlapping annotations"] = function()
  require("annotate").setup()
  store.add({ file = "a.lua", line = 1, line_end = 2, type = "report", text = "range" })
  store.add({ file = "a.lua", line = 1, type = "discuss", text = "single" })
  store.add({ file = "a.lua", line = 0, type = "context", text = "file" })
  local prompts = answer({ "All of them", "Yes" })

  api.delete()

  eq(prompts, { "Annotations", "Delete 2 annotations?" })
  eq(texts(), { "file" })
end

T["delete confirms unless forced"] = function()
  require("annotate").setup()
  store.add({ file = "a.lua", line = 1, type = "report", text = "one" })
  local prompts = answer({ "No" })

  api.delete()

  eq(#prompts, 1)
  eq(texts(), { "one" })

  prompts = answer({})
  api.delete({ force = true })

  eq(prompts, {})
  eq(texts(), {})
end

T["delete falls back to the whole-file annotation on line 1"] = function()
  require("annotate").setup({ confirm_delete = false })
  store.add({ file = "a.lua", line = 0, type = "context", text = "file" })
  store.add({ file = "a.lua", line = 2, type = "report", text = "two" })

  api.delete()

  eq(texts(), { "two" })
end

T["show opens a float with the annotation"] = function()
  require("annotate").setup()
  store.add({ file = "a.lua", line = 1, type = "report", text = "broken\nmore" })

  api.show()

  local floats = vim.tbl_filter(function(win)
    return vim.api.nvim_win_get_config(win).relative ~= ""
  end, vim.api.nvim_list_wins())
  eq(#floats, 1)
  local content = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(floats[1]), 0, -1, false), "\n")
  eq(content:find("Report", 1, true) ~= nil, true)
  eq(content:find("broken\nmore", 1, true) ~= nil, true)
end

T["show reports when there is no annotation under the cursor"] = function()
  require("annotate").setup()
  store.add({ file = "a.lua", line = 2, type = "report", text = "elsewhere" })
  local messages = {}
  vim.notify = function(message)
    table.insert(messages, message)
  end

  api.show()

  eq(messages, { "No annotation under the cursor." })
end

T["restore picks an archive by its label"] = function()
  require("annotate").setup()
  store.add({ file = "a.lua", line = 1, type = "report", text = "one" })
  store.add({ file = "a.lua", line = 2, type = "apply", text = "two" })
  store.archive()
  store.add({ file = "a.lua", line = 1, type = "report", text = "one" })
  local prompts = answer({ " · 2 notes · 1 apply, 1 report" })

  api.restore({ mode = "merge" })

  eq(prompts, { "Restore archive" })
  eq(texts(), { "one", "two" })
end

T["clear_archive removes only the archives of the repository"] = function()
  require("annotate").setup()
  store.add({ file = "a.lua", line = 1, type = "report", text = "one" })
  store.archive()
  local other = vim.fs.joinpath(store.archive_dir(), "0000000000000000-20200101-000000.json")
  vim.fn.writefile({ "{}" }, other)

  api.clear_archive({ force = true })

  eq(store.archives(), {})
  eq(vim.uv.fs_stat(other) ~= nil, true)
  os.remove(other)
end

---@param annotations annotate.Annotation[]
local function picker(annotations)
  local resumed = {}
  package.loaded.snacks = {
    picker = {
      resume = function(opts)
        table.insert(resumed, opts.source)
      end,
    },
  }

  return {
    opts = { source = "annotate" },
    closed = false,
    resumed = resumed,
    close = function(self)
      self.closed = true
    end,
    refreshed = 0,
    selected = function()
      return vim.tbl_map(function(annotation)
        return { annotation = annotation }
      end, annotations)
    end,
    refresh = function(self)
      self.refreshed = self.refreshed + 1
    end,
  }
end

T["delete action removes every selected annotation"] = function()
  require("annotate").setup({ confirm_delete = false })
  local first = store.add({ file = "a.lua", line = 1, type = "report", text = "one" })
  local second = store.add({ file = "a.lua", line = 2, type = "report", text = "two" })
  store.add({ file = "a.lua", line = 2, type = "report", text = "kept" })
  local p = picker({ first, second })

  api.actions.delete.action(p)

  eq(
    vim.tbl_map(function(annotation)
      return annotation.text
    end, store.load(true)),
    { "kept" }
  )
  eq(p.refreshed, 1)
end

T["delete action keeps the annotations when not confirmed"] = function()
  require("annotate").setup()
  answer({ "No" })
  local added = store.add({ file = "a.lua", line = 1, type = "report", text = "one" })
  local p = picker({ added })

  api.actions.delete.action(p)
  vim.wait(100, function()
    return #p.resumed > 0
  end)

  eq(#store.load(true), 1)
  eq({ p.closed, p.resumed }, { true, { "annotate" } })
end

T["delete action closes the picker while it confirms and reopens it after"] = function()
  require("annotate").setup()
  local closed
  local added = store.add({ file = "a.lua", line = 1, type = "report", text = "one" })
  local p = picker({ added })
  vim.ui.select = function(_, _, callback)
    closed = p.closed
    callback("Yes")
  end

  api.actions.delete.action(p)
  vim.wait(100, function()
    return #p.resumed > 0
  end)

  eq(closed, true)
  eq(#store.load(true), 0)
  eq(p.resumed, { "annotate" })
end

T["edit action closes the picker for the input and reopens it after"] = function()
  require("annotate").setup()
  local added = store.add({ file = "a.lua", line = 1, type = "report", text = "one" })
  local p = picker({ added })
  local closed
  input.open = function(_, callback)
    closed = p.closed
    callback("apply", "edited")
  end

  api.actions.edit.action(p, { annotation = added })
  vim.wait(100, function()
    return #p.resumed > 0
  end)

  eq(closed, true)
  eq(store.load(true)[1].text, "edited")
  eq(p.resumed, { "annotate" })
end

T["split action closes the picker and leaves it closed once confirmed"] = function()
  require("annotate").setup()
  answer({ "Yes" })
  local added = store.add({ file = "a.lua", line = 1, type = "report", text = "one" })
  store.add({ file = "a.lua", line = 2, type = "report", text = "two" })
  local p = picker({ added })

  api.actions.split.action(p)
  vim.wait(50)

  eq(p.closed, true)
  eq(p.resumed, {})
  eq(#store.load(true), 1)
end

T["type action cycles to the next type and wraps around"] = function()
  require("annotate").setup()
  local report = store.add({ file = "a.lua", line = 1, type = "report", text = "one" })
  local context = store.add({ file = "a.lua", line = 2, type = "context", text = "two" })
  local p = picker({ report, context })

  api.actions.type.action(p)

  store.load(true)
  eq(store.get(report.id).type, "keep")
  eq(store.get(context.id).type, "apply")
  eq(p.refreshed, 1)
end

T["restore into a non-empty store archives it first and replaces it"] = function()
  require("annotate").setup()
  store.add({ file = "a.lua", line = 1, type = "report", text = "archived" })
  store.archive()
  store.add({ file = "a.lua", line = 2, type = "report", text = "current" })
  local prompts = answer({ " · 1 notes · 1 report" })

  api.restore()

  eq(prompts, { "Restore archive" })
  eq(texts(), { "archived" })
  eq(#store.archives(), 1)
  eq(store.read(store.archives()[1])[1].text, "current")
end

T["restore merges only when asked to"] = function()
  require("annotate").setup()
  store.add({ file = "a.lua", line = 1, type = "report", text = "archived" })
  store.archive()
  store.add({ file = "a.lua", line = 2, type = "report", text = "current" })
  answer({ " · 1 notes · 1 report" })

  api.restore({ mode = "merge" })

  eq(texts(), { "current", "archived" })
  eq(store.archives(), {})
end

---@param selected annotate.Annotation[]
---@param current annotate.Annotation
local function selecting(selected, current)
  return {
    opts = { source = "annotate" },
    closed = false,
    selected = function(_, opts)
      local items = vim.tbl_map(function(annotation)
        return { annotation = annotation }
      end, selected)

      return (#items == 0 and opts.fallback) and { { annotation = current } } or items
    end,
    close = function(self)
      self.closed = true
    end,
  }
end

T["split keeps the selected notes and archives a snapshot of all of them"] = function()
  require("annotate").setup({ picker = { force = { split = true } } })
  local kept = store.add({ file = "a.lua", line = 1, type = "report", text = "kept" })
  store.update(kept.id, { posted = { { platform = "gitlab", target = 5, id = 1, state = "draft" } } })
  local other = store.add({ file = "a.lua", line = 2, type = "report", text = "other" })
  local messages = {}
  vim.notify = function(message)
    table.insert(messages, message)
  end
  local p = selecting({ kept }, other)

  api.actions.split.action(p)

  eq(p.closed, true)
  local stored = store.load(true)
  eq(#stored, 1)
  eq({ stored[1].id, stored[1].text, stored[1].posted[1].target }, { kept.id, "kept", 5 })
  eq(
    vim.tbl_map(function(annotation)
      return annotation.text
    end, store.read(store.archives()[1])),
    { "kept", "other" }
  )
  eq(messages, { "Kept 1 notes, archived 2." })
end

T["split without a selection keeps the note under the cursor after confirmation"] = function()
  require("annotate").setup()
  store.add({ file = "a.lua", line = 1, type = "report", text = "archived" })
  local current = store.add({ file = "a.lua", line = 2, type = "report", text = "current" })
  local prompts = answer({ "Yes" })

  api.actions.split.action(selecting({}, current))

  eq(prompts, { "Archive all 2 annotations and keep the 1 selected?" })
  eq(texts(), { "current" })
end

T["add_repository stores a note attached to no file"] = function()
  input.open = function(_, callback)
    callback("consider", "about everything")
  end

  api.add_repository()

  local stored = store.load(true)
  eq({ stored[1].file, stored[1].line, stored[1].text }, { nil, 0, "about everything" })
end

---@param state string
---@param reference string
---@return annotate.Posted
local function posted(state, reference)
  return { state = state, reference = reference, platform = "gitlab", target = 5 }
end

T["picker rows show the type, location, first line and where the note was posted"] = function()
  require("annotate").setup()
  local range = store.add({ type = "report", file = "a.lua", line = 1, line_end = 2, text = "broken\nmore" })
  store.update(range.id, { posted = { posted("draft", "!5"), posted("published", "#1") } })
  local whole = store.add({ type = "discuss", file = "a.lua", line = 0, text = "why" })
  local rev = store.add({ type = "apply", file = "a.lua", line = 2, rev = "abcdef12345", text = "old" })
  local repository = store.add({ type = "consider", line = 0, text = "overall" })
  store.update(repository.id, { posted = { posted("queued", "#1") } })

  eq(vim.tbl_map(api.describe, { store.get(range.id), whole, rev, store.get(repository.id) }), {
    require("annotate.config").type("report").icon .. " Report  a.lua:1-2  broken  draft !5, published #1",
    require("annotate.config").type("discuss").icon .. " Discuss  a.lua  why",
    require("annotate.config").type("apply").icon .. " Apply  a.lua:~2 @ abcdef12345  old",
    require("annotate.config").type("consider").icon .. " Consider  repository  overall  queued #1",
  })
end

T["pick lists the current branch, and with all copies a note of another branch before jumping to it"] = function()
  require("annotate").setup({ store = { per_branch = true } })
  vim.system({ "git", "symbolic-ref", "HEAD", "refs/heads/feature" }):wait()
  local theirs = store.add({ type = "report", file = "a.lua", line = 2, text = "from feature" })
  store.update(theirs.id, { posted = { posted("draft", "!5") } })
  vim.system({ "git", "symbolic-ref", "HEAD", "refs/heads/main" }):wait()
  store.add({ type = "apply", file = "a.lua", line = 1, text = "on main" })

  local offered
  vim.ui.select = function(items, opts, callback)
    offered = vim.tbl_map(opts.format_item, items)
    callback(nil)
  end
  api.pick()
  eq(#offered, 1)

  local prompts = answer({ "[feature]" })
  api.pick({ all = true })

  eq(prompts, { "Annotations" })
  eq(texts(), { "on main", "from feature" })
  eq(store.load(true)[2].posted, nil)
  eq(vim.api.nvim_win_get_cursor(0)[1], 2)

  answer({ "[feature]" })
  api.pick({ all = true })
  eq(#store.load(true), 2)
end

T["quickfix lists every note, repository notes without a file"] = function()
  local pinned = store.add({ type = "report", file = "a.lua", line = 2, text = "pinned" })
  store.update(pinned.id, { posted = { posted("draft", "!5") } })
  local repository = store.add({ type = "consider", line = 0, text = "repository\nmore" })
  require("annotate").setup({ quickfix = { open = false } })

  api.quickfix()

  local items = vim.fn.getqflist({ items = 1 }).items
  eq(
    vim.tbl_map(function(item)
      return { item.text, item.valid, item.lnum, item.type, item.bufnr ~= 0, item.user_data }
    end, items),
    {
      { "[REPORT] a.lua:2  pinned  (draft !5)", 1, 2, "R", true, { id = pinned.id, type = "report", reach = "here", posted = "draft !5" } },
      { "[CONSIDER] repository  repository", 0, 0, "C", false, { id = repository.id, type = "consider", reach = "here" } },
    }
  )
end

---@param fake table
---@return string[]
local function written(fake)
  return vim.api.nvim_buf_get_lines(fake.win.buf, 0, -1, false)
end

--- Opens the real input on a fake snacks.nvim window over `a.lua` with the cursor on line 2.
---@return table
local function rewriting()
  input.open = open
  require("annotate").setup({ picker = { backend = "select" } })
  vim.bo.filetype = "lua"
  vim.api.nvim_win_set_cursor(0, { 2, 0 })

  return H.snacks()
end

T["add prefills a rewrite with the current line"] = function()
  local fake = rewriting()

  api.add({ type = "rewrite" })

  eq(written(fake), { "```lua", "two", "```" })
  eq(vim.api.nvim_win_get_cursor(fake.win.win), { 2, 0 })
end

T["add prefills a rewrite with the visual selection"] = function()
  local fake = rewriting()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.api.nvim_feedkeys("Vj", "nx!", false)

  api.add({ type = "rewrite" })

  eq(written(fake), { "```lua", "one", "two", "```" })
end

T["cycling onto rewrite prefills, away from an untouched prefill empties, and user text stays"] = function()
  local fake = rewriting()
  local keys = require("annotate.config").options.input.keys

  api.add()
  eq(written(fake), { "" })

  H.press(fake, keys.cycle)
  eq(written(fake), { "```lua", "two", "```" })

  H.press(fake, keys.cycle_prev)
  eq(written(fake), { "" })

  H.press(fake, keys.cycle)
  vim.api.nvim_buf_set_lines(fake.win.buf, 1, 2, false, { "TWO" })
  H.press(fake, keys.cycle_prev)
  eq(written(fake), { "```lua", "TWO", "```" })

  vim.api.nvim_buf_set_lines(fake.win.buf, 0, -1, false, { "mine" })
  H.press(fake, keys.cycle)
  eq(written(fake), { "mine" })
end

T["add_with_type prefills from the buffer and line captured before the type chooser"] = function()
  local fake = rewriting()
  local origin = vim.api.nvim_get_current_buf()
  vim.ui.select = function(items, _, callback)
    vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(true, true))
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    callback(items[2])
  end

  api.add_with_type()

  eq(written(fake), { "```lua", "two", "```" })
  eq(vim.b[fake.win.buf].annotate_origin, origin)
end

T["edit keeps the text of a rewrite"] = function()
  local fake = rewriting()
  store.add({ file = "a.lua", line = 2, type = "rewrite", text = "```lua\nTWO\n```" })

  api.edit()

  eq(written(fake), { "```lua", "TWO", "```" })
end

T["the reach key cycles the reaches of the type and submits the chosen one"] = function()
  local fake = rewriting()
  local keys = require("annotate.config").options.input.keys

  api.add()
  eq(fake.win.opts.footer:find("[here] · pattern", 1, true) ~= nil, true)

  H.press(fake, keys.reach)
  eq(vim.api.nvim_win_get_config(fake.win.win).footer[1][1]:find("here · [pattern]", 1, true) ~= nil, true)

  vim.api.nvim_buf_set_lines(fake.win.buf, 0, -1, false, { "everywhere" })
  H.press(fake, keys.submit)
  vim.wait(100, function()
    return #store.load(true) > 0
  end)

  local added = store.load(true)[1]
  eq({ added.type, added.reach, added.text }, { "apply", "pattern", "everywhere" })
end

T["cycling onto a type without the reach falls back to its default"] = function()
  local fake = rewriting()
  local keys = require("annotate.config").options.input.keys

  api.add()
  H.press(fake, keys.reach)
  H.press(fake, keys.cycle)
  vim.api.nvim_buf_set_lines(fake.win.buf, 0, -1, false, { "replacement" })
  H.press(fake, keys.submit)
  vim.wait(100, function()
    return #store.load(true) > 0
  end)

  local added = store.load(true)[1]
  eq({ added.type, added.reach }, { "rewrite", nil })
end

T["the selection key inserts the annotated lines below the cursor"] = function()
  local fake = rewriting()
  local keys = require("annotate.config").options.input.keys

  api.add()
  vim.api.nvim_buf_set_lines(fake.win.buf, 0, -1, false, { "use this:" })
  H.press(fake, keys.selection)

  eq(written(fake), { "use this:", "```lua", "two", "```" })
end

T["edit clears a reach set back to the default"] = function()
  require("annotate").setup()
  local wide = store.add({ file = "a.lua", line = 1, type = "apply", reach = "pattern", text = "wide" })
  local edit
  input.open = function(opts, callback)
    edit = opts
    callback("apply", "narrow", nil)
  end

  api.edit()

  eq(edit.reach, "pattern")
  store.load(true)
  eq({ store.get(wide.id).text, store.get(wide.id).reach }, { "narrow", nil })
end

T["type action drops a reach the next type does not have"] = function()
  require("annotate").setup()
  local wide = store.add({ file = "a.lua", line = 1, type = "apply", reach = "pattern", text = "wide" })

  api.actions.type.action(picker({ wide }))

  store.load(true)
  eq({ store.get(wide.id).type, store.get(wide.id).reach }, { "rewrite", nil })
end

return T
