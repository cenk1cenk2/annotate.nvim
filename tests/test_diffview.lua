local eq = MiniTest.expect.equality

local diffview = require("annotate.sources.diffview")

local T = MiniTest.new_set()

T["parses a commit buffer"] = function()
  eq(diffview.parse("diffview:///home/me/repo/.git/abcdef12345/lua/a/b.lua"), {
    gitdir = "/home/me/repo/.git",
    rev = "abcdef12345",
    path = "lua/a/b.lua",
  })
end

T["parses a stage buffer"] = function()
  eq(diffview.parse("diffview:///home/me/repo/.git/:2:/b.lua"), {
    gitdir = "/home/me/repo/.git",
    rev = ":2:",
    path = "b.lua",
  })
end

T["parses a custom buffer"] = function()
  eq(diffview.parse("diffview:///home/me/repo/.git/[custom]/dir/b.lua"), {
    gitdir = "/home/me/repo/.git",
    rev = "[custom]",
    path = "dir/b.lua",
  })
end

T["rejects other buffers"] = function()
  eq(diffview.parse("/home/me/repo/b.lua"), nil)
  eq(diffview.parse("diffview://null"), nil)
  eq(diffview.parse("diffview:///home/me/repo/.git/abcdef12345"), nil)
end

T["formats revisions like buffer names"] = function()
  eq(
    diffview.rev({
      commit = "abcdef1234567890",
      abbrev = function(self, length)
        return self.commit:sub(1, length)
      end,
    }),
    "abcdef12345"
  )
  eq(diffview.rev({ stage = 0 }), ":0:")
  eq(
    diffview.rev(setmetatable({}, {
      __tostring = function()
        return "LOCAL"
      end,
    })),
    "LOCAL"
  )
end

T["has no context without diffview"] = function()
  eq(diffview.context(), nil)
end

return T
