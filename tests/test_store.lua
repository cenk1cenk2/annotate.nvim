local H = dofile("tests/helpers.lua")
local eq = MiniTest.expect.equality

local store = require("annotate.store")

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      H.repo()
    end,
  },
})

T["add persists and reloads"] = function()
  local added = store.add({ file = "a.lua", line = 3, type = "bug", text = "broken" })

  local reloaded = store.load(true)

  eq(#reloaded, 1)
  eq(reloaded[1].id, added.id)
  eq(reloaded[1].text, "broken")
  eq(reloaded[1].rev, nil)
end

T["update changes fields and clears nil values"] = function()
  local added = store.add({ file = "a.lua", line = 3, line_end = 5, type = "bug", text = "broken" })

  store.update(added.id, { text = "still broken", line_end = vim.NIL })

  local reloaded = store.load(true)[1]
  eq(reloaded.text, "still broken")
  eq(reloaded.line_end, nil)
end

T["update of an unknown id errors"] = function()
  MiniTest.expect.error(function()
    store.update("missing", { text = "x" })
  end, "no annotation with id")
end

T["delete removes the annotation"] = function()
  local first = store.add({ file = "a.lua", line = 1, type = "general", text = "one" })
  store.add({ file = "a.lua", line = 2, type = "general", text = "two" })

  store.delete(first.id)

  local reloaded = store.load(true)
  eq(#reloaded, 1)
  eq(reloaded[1].text, "two")
end

T["get_at matches ranges, revisions and whole-file notes"] = function()
  store.add({ file = "a.lua", line = 4, line_end = 6, type = "bug", text = "range" })
  store.add({ file = "a.lua", line = 5, rev = "abcdef12345", type = "bug", text = "rev" })
  store.add({ file = "a.lua", line = 0, type = "context", text = "file" })

  eq(store.get_at("a.lua", 5).text, "range")
  eq(store.get_at("a.lua", 5, "abcdef12345").text, "rev")
  eq(store.get_at("a.lua", 0).text, "file")
  eq(store.get_at("a.lua", 7), nil)
end

T["archive moves the file and clears the store"] = function()
  store.add({ file = "a.lua", line = 1, type = "general", text = "one" })
  local path = store.path()

  local archived = store.archive()

  eq(vim.uv.fs_stat(path), nil)
  eq(vim.uv.fs_stat(archived) ~= nil, true)
  eq(vim.startswith(archived, store.archive_dir()), true)
  eq(#store.all(), 0)
  eq(#store.load(true), 0)
end

T["prune removes archives older than 30 days"] = function()
  vim.fn.mkdir(store.archive_dir(), "p")
  local old = vim.fs.joinpath(store.archive_dir(), "old.json")
  local fresh = vim.fs.joinpath(store.archive_dir(), "fresh.json")
  vim.fn.writefile({ "{}" }, old)
  vim.fn.writefile({ "{}" }, fresh)
  local past = os.time() - 31 * 24 * 60 * 60
  vim.uv.fs_utime(old, past, past)

  store.prune()

  eq(vim.uv.fs_stat(old), nil)
  eq(vim.uv.fs_stat(fresh) ~= nil, true)
end

return T
