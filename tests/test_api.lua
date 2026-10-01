local H = dofile("tests/helpers.lua")
local eq = MiniTest.expect.equality

local api = require("annotate.api")
local input = require("annotate.input")
local store = require("annotate.store")

local open = input.open
local opened

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
      require("annotate").setup()
      vim.cmd("silent! %bwipeout!")
    end,
  },
})

T["starts the input on the first type"] = function()
  require("annotate").setup()

  api.add()

  eq(opened.type, "general")
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
  local select = vim.ui.select
  vim.ui.select = function(_, _, callback)
    callback("No")
  end
  local added = store.add({ file = "a.lua", line = 1, type = "bug", text = "one" })
  local p = picker({ added })

  api.actions.delete.action(p)
  vim.ui.select = select

  eq(#store.load(true), 1)
  eq(p.refreshed, 0)
end

T["type action cycles to the next type and wraps around"] = function()
  require("annotate").setup()
  local bug = store.add({ file = "a.lua", line = 1, type = "bug", text = "one" })
  local context = store.add({ file = "a.lua", line = 2, type = "context", text = "two" })
  local p = picker({ bug, context })

  api.actions.type.action(p)

  store.load(true)
  eq(store.get(bug.id).type, "question")
  eq(store.get(context.id).type, "general")
  eq(p.refreshed, 1)
end

return T
