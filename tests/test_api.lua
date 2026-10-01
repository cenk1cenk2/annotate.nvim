local H = dofile("tests/helpers.lua")
local eq = MiniTest.expect.equality

local api = require("annotate.api")
local input = require("annotate.input")

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

return T
