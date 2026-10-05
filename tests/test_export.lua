local H = dofile("tests/helpers.lua")
local eq = MiniTest.expect.equality

local config = require("annotate.config")
local export = require("annotate.export")
local store = require("annotate.store")

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
    note({ type = "report", file = "b.lua", line = 12, text = "second file" }),
    note({ type = "report", file = "a.lua", line = 20, line_end = 24, text = "range" }),
    note({ type = "consider", file = "a.lua", line = 3, text = "first line\nsecond line" }),
  })

  eq(
    markdown,
    table.concat({
      "PROMPT",
      "",
      "## Description",
      "",
      "- [CONSIDER] (here): " .. config.type("consider").export.prompt,
      "- [REPORT] (here): " .. config.type("report").export.prompt,
      "",
      "## [CONSIDER] (here)",
      "",
      "### `a.lua:3`",
      "",
      "first line",
      "second line",
      "",
      "---",
      "",
      "## [REPORT] (here)",
      "",
      "### `a.lua:20-24`",
      "",
      "range",
      "",
      "### `b.lua:12`",
      "",
      "second file",
      "",
    }, "\n")
  )
end

T["lists each comparison once only when a context exists"] = function()
  local context = { left = "abcdef12345", right = "LOCAL" }
  local markdown = export.render({
    note({ type = "discuss", file = "a.lua", line = 5, rev = "abcdef12345", context = context, text = "why" }),
    note({ type = "discuss", file = "a.lua", line = 0, rev = ":0:", context = context, text = "staged" }),
    note({ type = "discuss", file = "a.lua", line = 0, text = "whole" }),
  })

  eq(markdown:find("## Compared\n\n- `abcdef12345` .. `LOCAL`\n\n## [DISCUSS]", 1, true) ~= nil, true)
  eq(select(2, markdown:gsub("`abcdef12345` %.%. `LOCAL`", "")), 1)
  eq(markdown:find("### `a.lua`\n\nwhole", 1, true) ~= nil, true)
  eq(markdown:find("### `a.lua @ :0:`\n\nstaged", 1, true) ~= nil, true)
  eq(markdown:find("### `a.lua:~5 @ abcdef12345`\n\nwhy", 1, true) ~= nil, true)
  eq(markdown:find("---", 1, true), nil)
end

T["omits Compared without context"] = function()
  local markdown = export.render({ note({ type = "keep", file = "a.lua", line = 1, text = "nice" }) })

  eq(markdown:find("## Compared", 1, true), nil)
end

T["filters to the requested types"] = function()
  local markdown = export.render({
    note({ type = "report", file = "a.lua", line = 1, text = "kept" }),
    note({ type = "keep", file = "a.lua", line = 2, text = "dropped" }),
  }, { types = { "report" } })

  eq(markdown:find("PRAISE", 1, true), nil)
  eq(markdown:find("### `a.lua:1`\n\nkept", 1, true) ~= nil, true)
end

T["uses the configured headings, separator and label"] = function()
  config.setup({
    export = {
      prompt = "PROMPT",
      headings = { description = "Legend", compared = "Diff" },
      separator = "***",
      label = function(t)
        return t.key
      end,
    },
  })

  local markdown = export.render({
    note({ type = "report", file = "a.lua", line = 1, text = "broken", context = { left = "HEAD", right = "LOCAL" } }),
    note({ type = "keep", file = "a.lua", line = 2, text = "nice" }),
  })

  eq(markdown:find("## Description", 1, true), nil)
  eq(markdown:find("## Legend\n\n- report: ", 1, true) ~= nil, true)
  eq(markdown:find("## Diff\n\n- `HEAD` .. `LOCAL`", 1, true) ~= nil, true)
  eq(markdown:find("## report\n\n### `a.lua:1`\n\nbroken\n\n***\n\n## keep\n", 1, true) ~= nil, true)
  eq(markdown:find("---", 1, true), nil)
end

T["format replaces the built-in renderer"] = function()
  local received
  config.setup({
    export = {
      prompt = "PROMPT",
      format = function(annotations, opts, c)
        received = { annotations = annotations, opts = opts, prompt = c.export.prompt }

        return "custom"
      end,
    },
  })

  local annotations = { note({ type = "report", file = "a.lua", line = 1, text = "broken" }) }

  eq(export.render(annotations, { types = { "report" } }), "custom")
  eq(received, { annotations = annotations, opts = { types = { "report" } }, prompt = "PROMPT" })
end

T["writes the file to export.dir with export.filename"] = function()
  local dir = vim.fn.tempname()
  local repository
  config.setup({
    export = {
      to = "file",
      dir = dir,
      filename = function(name)
        repository = name

        return "notes.md"
      end,
    },
  })
  local root = H.repo()
  store.add({ file = "a.lua", line = 1, type = "report", text = "broken" })

  local markdown = export.export()

  eq(repository, vim.fs.basename(root))
  eq(table.concat(vim.fn.readfile(vim.fs.joinpath(dir, "notes.md")), "\n") .. "\n", markdown)
end

T["formats revision ranges"] = function()
  eq(export.location(note({ file = "a.lua", line = 2, line_end = 4, rev = "abcdef12345" })), "a.lua:~2-4 @ abcdef12345")
end

T["renders repository notes without a location, before file notes"] = function()
  local markdown = export.render({
    note({ type = "consider", file = "a.lua", line = 3, text = "pinned" }),
    note({ type = "consider", line = 0, text = "about the whole repository" }),
  })

  eq(markdown:match("## %[CONSIDER%] %(here%)\n\n(.-)\n$"), "### repository\n\nabout the whole repository\n\n### `a.lua:3`\n\npinned")
end

T["splits a type by reach and uses the prompt of each reach"] = function()
  local markdown = export.render({
    note({ type = "apply", file = "a.lua", line = 1, text = "here" }),
    note({ type = "apply", file = "a.lua", line = 2, reach = "pattern", text = "everywhere" }),
  })

  local apply = config.type("apply")
  eq(markdown:find(("- [APPLY] (here): %s\n- [APPLY] (pattern): %s\n"):format(apply.export.prompt, apply.export.reach.pattern), 1, true) ~= nil, true)
  eq(markdown:find("## [APPLY] (here)\n\n### `a.lua:1`\n\nhere\n\n---\n\n## [APPLY] (pattern)\n\n### `a.lua:2`\n\neverywhere\n", 1, true) ~= nil, true)
  eq(markdown:find("## Reach", 1, true), nil)
end

T["lists the meaning of the used reaches when export.reach is set"] = function()
  config.setup({ export = { prompt = "PROMPT", reach = { here = "HERE", pattern = "PATTERN" } } })

  local markdown = export.render({
    note({ type = "apply", file = "a.lua", line = 2, reach = "pattern", text = "everywhere" }),
  })

  eq(markdown:find("\n\n## Reach\n\n- pattern: PATTERN\n", 1, true) ~= nil, true)
end

return T
