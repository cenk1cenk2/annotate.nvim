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

  eq(opened.type, "issue")
end

T["starts the input on default_type"] = function()
  require("annotate").setup({ default_type = "bug" })

  api.add()

  eq(opened.type, "bug")
end

T["an explicit type wins over default_type"] = function()
  require("annotate").setup({ default_type = "bug" })

  api.add_file({ type = "question" })

  eq(opened.type, "question")
end

T["add_with_type stores the chosen type on the visual selection"] = function()
  require("annotate").setup()
  local prompts = answer({ "Bug" })
  input.open = function(opts, callback)
    opened = opts
    callback(opts.type, "chosen")
  end

  vim.api.nvim_feedkeys("Vj", "nx!", false)
  eq(vim.fn.mode(), "V")
  api.add_with_type()

  eq(prompts, { "Annotation type" })
  eq(opened.type, "bug")
  local added = store.load(true)[1]
  eq({ added.type, added.line, added.line_end, added.text }, { "bug", 1, 2, "chosen" })
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
  store.add({ file = "a.lua", line = 1, line_end = 2, type = "bug", text = "range" })
  local single = store.add({ file = "a.lua", line = 1, type = "question", text = "single" })
  local prompts = answer({ "Question: single (a.lua:1)" })
  local edit
  input.open = function(opts, callback)
    edit = opts
    callback("praise", "changed")
  end

  api.edit()

  eq(prompts, { "Annotations" })
  eq(edit, { type = "question", text = "single" })
  eq(store.get(single.id).text, "changed")
  eq(texts(), { "range", "changed" })
end

T["delete removes only the chosen overlapping annotation"] = function()
  require("annotate").setup({ confirm_delete = false })
  store.add({ file = "a.lua", line = 1, line_end = 2, type = "bug", text = "range" })
  store.add({ file = "a.lua", line = 1, type = "question", text = "single" })
  answer({ "Bug: range (a.lua:1-2)" })

  api.delete()

  eq(texts(), { "single" })
end

T["delete removes all of the overlapping annotations"] = function()
  require("annotate").setup()
  store.add({ file = "a.lua", line = 1, line_end = 2, type = "bug", text = "range" })
  store.add({ file = "a.lua", line = 1, type = "question", text = "single" })
  store.add({ file = "a.lua", line = 0, type = "context", text = "file" })
  local prompts = answer({ "All of them", "Yes" })

  api.delete()

  eq(prompts, { "Annotations", "Delete 2 annotations?" })
  eq(texts(), { "file" })
end

T["delete confirms unless forced"] = function()
  require("annotate").setup()
  store.add({ file = "a.lua", line = 1, type = "bug", text = "one" })
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
  store.add({ file = "a.lua", line = 2, type = "bug", text = "two" })

  api.delete()

  eq(texts(), { "two" })
end

T["show opens a float with the annotation"] = function()
  require("annotate").setup()
  store.add({ file = "a.lua", line = 1, type = "bug", text = "broken\nmore" })

  api.show()

  local floats = vim.tbl_filter(function(win)
    return vim.api.nvim_win_get_config(win).relative ~= ""
  end, vim.api.nvim_list_wins())
  eq(#floats, 1)
  local content = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(floats[1]), 0, -1, false), "\n")
  eq(content:find("Bug", 1, true) ~= nil, true)
  eq(content:find("broken\nmore", 1, true) ~= nil, true)
end

T["show reports when there is no annotation under the cursor"] = function()
  require("annotate").setup()
  store.add({ file = "a.lua", line = 2, type = "bug", text = "elsewhere" })
  local messages = {}
  vim.notify = function(message)
    table.insert(messages, message)
  end

  api.show()

  eq(messages, { "No annotation under the cursor." })
end

T["restore picks an archive by its label"] = function()
  require("annotate").setup()
  store.add({ file = "a.lua", line = 1, type = "bug", text = "one" })
  store.add({ file = "a.lua", line = 2, type = "issue", text = "two" })
  store.archive()
  store.add({ file = "a.lua", line = 1, type = "bug", text = "one" })
  local prompts = answer({ " · 2 notes · 1 issue, 1 bug" })

  api.restore({ mode = "merge" })

  eq(prompts, { "Restore archive" })
  eq(texts(), { "one", "two" })
end

T["clear_archive removes only the archives of the repository"] = function()
  require("annotate").setup()
  store.add({ file = "a.lua", line = 1, type = "bug", text = "one" })
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
  return {
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
  local first = store.add({ file = "a.lua", line = 1, type = "bug", text = "one" })
  local second = store.add({ file = "a.lua", line = 2, type = "bug", text = "two" })
  store.add({ file = "a.lua", line = 2, type = "bug", text = "kept" })
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
  local added = store.add({ file = "a.lua", line = 1, type = "bug", text = "one" })
  local p = picker({ added })

  api.actions.delete.action(p)

  eq(#store.load(true), 1)
  eq(p.refreshed, 0)
end

T["type action cycles to the next type and wraps around"] = function()
  require("annotate").setup()
  local bug = store.add({ file = "a.lua", line = 1, type = "bug", text = "one" })
  local praise = store.add({ file = "a.lua", line = 2, type = "praise", text = "two" })
  local p = picker({ bug, praise })

  api.actions.type.action(p)

  store.load(true)
  eq(store.get(bug.id).type, "context")
  eq(store.get(praise.id).type, "issue")
  eq(p.refreshed, 1)
end

T["restore into a non-empty store archives it first and replaces it"] = function()
  require("annotate").setup()
  store.add({ file = "a.lua", line = 1, type = "bug", text = "archived" })
  store.archive()
  store.add({ file = "a.lua", line = 2, type = "bug", text = "current" })
  local prompts = answer({ " · 1 notes · 1 bug" })

  api.restore()

  eq(prompts, { "Restore archive" })
  eq(texts(), { "archived" })
  eq(#store.archives(), 1)
  eq(store.read(store.archives()[1])[1].text, "current")
end

T["restore merges only when asked to"] = function()
  require("annotate").setup()
  store.add({ file = "a.lua", line = 1, type = "bug", text = "archived" })
  store.archive()
  store.add({ file = "a.lua", line = 2, type = "bug", text = "current" })
  answer({ " · 1 notes · 1 bug" })

  api.restore({ mode = "merge" })

  eq(texts(), { "current", "archived" })
  eq(store.archives(), {})
end

---@param selected annotate.Annotation[]
---@param current annotate.Annotation
local function selecting(selected, current)
  return {
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
  local kept = store.add({ file = "a.lua", line = 1, type = "bug", text = "kept" })
  store.update(kept.id, { posted = { { platform = "gitlab", target = 5, id = 1, state = "draft" } } })
  local other = store.add({ file = "a.lua", line = 2, type = "bug", text = "other" })
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
  store.add({ file = "a.lua", line = 1, type = "bug", text = "archived" })
  local current = store.add({ file = "a.lua", line = 2, type = "bug", text = "current" })
  local prompts = answer({ "Yes" })

  api.actions.split.action(selecting({}, current))

  eq(prompts, { "Archive all 2 annotations and keep the 1 selected?" })
  eq(texts(), { "current" })
end

T["add_repository stores a note attached to no file"] = function()
  input.open = function(_, callback)
    callback("general", "about everything")
  end

  api.add_repository()

  local stored = store.load(true)
  eq({ stored[1].file, stored[1].line, stored[1].text }, { nil, 0, "about everything" })
end

T["quickfix leaves repository notes out"] = function()
  store.add({ type = "general", line = 0, text = "repository" })
  store.add({ type = "bug", file = "a.lua", line = 1, text = "pinned" })
  require("annotate").setup({ quickfix = { open = false } })

  api.quickfix()

  eq(
    vim.tbl_map(function(item)
      return item.text:match("pinned") ~= nil
    end, vim.fn.getqflist()),
    { true }
  )
end

return T
