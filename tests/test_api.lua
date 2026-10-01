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

return T
