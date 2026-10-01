local eq = MiniTest.expect.equality

local config = require("annotate.config")

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      config.setup({
        types = {
          { key = "a", name = "A", icon = "1", hl = "Comment", prompt = "" },
          { key = "b", name = "B", icon = "2", hl = "Comment", prompt = "" },
          { key = "c", name = "C", icon = "3", hl = "Comment", prompt = "" },
        },
      })
    end,
    post_case = function()
      config.setup()
    end,
  },
})

T["title lists every type with the current one in brackets"] = function()
  local types = config.options.types

  eq(config.resolve(config.options.input.title, types[2], config.options.input.keys, types, 2), " 1 A · [2 B] · 3 C ")
end

T["footer names both cycle keys"] = function()
  local types = config.options.types

  eq(config.resolve(config.options.input.footer, types[1], config.options.input.keys, types, 1), " <C-p>/<C-n> cycle  <C-s> submit  q cancel ")
end

return T
