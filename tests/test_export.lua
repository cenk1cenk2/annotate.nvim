local eq = MiniTest.expect.equality

local config = require("annotate.config")
local export = require("annotate.export")

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      config.setup({ export = { prompt = "PROMPT" } })
    end,
  },
})

local function note(fields)
  return vim.tbl_extend("force", { id = "x", created_at = 0 }, fields)
end

T["renders used types in config order with separators"] = function()
  local markdown = export.render({
    note({ type = "bug", file = "b.lua", line = 12, text = "second file" }),
    note({ type = "bug", file = "a.lua", line = 20, line_end = 24, text = "range" }),
    note({ type = "general", file = "a.lua", line = 3, text = "first line\nsecond line" }),
  })

  eq(
    markdown,
    table.concat({
      "PROMPT",
      "",
      "## Description",
      "",
      "- [GENERAL]: " .. config.type("general").prompt,
      "- [BUG]: " .. config.type("bug").prompt,
      "",
      "## [GENERAL]",
      "",
      "- `a.lua:3` - first line",
      "  second line",
      "",
      "---",
      "",
      "## [BUG]",
      "",
      "- `a.lua:20-24` - range",
      "- `b.lua:12` - second file",
      "",
    }, "\n")
  )
end

T["lists each comparison once only when a context exists"] = function()
  local context = { left = "abcdef12345", right = "LOCAL" }
  local markdown = export.render({
    note({ type = "question", file = "a.lua", line = 5, rev = "abcdef12345", context = context, text = "why" }),
    note({ type = "question", file = "a.lua", line = 0, rev = ":0:", context = context, text = "staged" }),
    note({ type = "question", file = "a.lua", line = 0, text = "whole" }),
  })

  eq(markdown:find("## Compared\n\n- `abcdef12345` .. `LOCAL`\n\n## [QUESTION]", 1, true) ~= nil, true)
  eq(select(2, markdown:gsub("`abcdef12345` %.%. `LOCAL`", "")), 1)
  eq(markdown:find("- `a.lua` - whole", 1, true) ~= nil, true)
  eq(markdown:find("- `a.lua @ :0:` - staged", 1, true) ~= nil, true)
  eq(markdown:find("- `a.lua:~5 @ abcdef12345` - why", 1, true) ~= nil, true)
  eq(markdown:find("---", 1, true), nil)
end

T["omits Compared without context"] = function()
  local markdown = export.render({ note({ type = "praise", file = "a.lua", line = 1, text = "nice" }) })

  eq(markdown:find("## Compared", 1, true), nil)
end

T["filters to the requested types"] = function()
  local markdown = export.render({
    note({ type = "bug", file = "a.lua", line = 1, text = "kept" }),
    note({ type = "praise", file = "a.lua", line = 2, text = "dropped" }),
  }, { types = { "bug" } })

  eq(markdown:find("PRAISE", 1, true), nil)
  eq(markdown:find("- `a.lua:1` - kept", 1, true) ~= nil, true)
end

T["formats revision ranges"] = function()
  eq(export.location(note({ file = "a.lua", line = 2, line_end = 4, rev = "abcdef12345" })), "a.lua:~2-4 @ abcdef12345")
end

return T
