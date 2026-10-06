local H = dofile("tests/helpers.lua")
local eq = MiniTest.expect.equality

local config = require("annotate.config")
local store = require("annotate.store")

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      config.setup()
      H.repo()
    end,
  },
})

T["keeps the store under store.dir"] = function()
  local dir = vim.fn.tempname()
  config.setup({ store = { dir = dir } })

  store.add({ file = "a.lua", line = 1, type = "report", text = "broken" })

  eq(vim.startswith(store.path(), dir), true)
  eq(vim.uv.fs_stat(store.path()) ~= nil, true)
  eq(vim.startswith(store.archive_dir(), dir), true)
end

T["add persists and reloads"] = function()
  local added = store.add({ file = "a.lua", line = 3, type = "report", text = "broken" })

  local reloaded = store.load(true)

  eq(#reloaded, 1)
  eq(reloaded[1].id, added.id)
  eq(reloaded[1].text, "broken")
  eq(reloaded[1].rev, nil)
end

T["update changes fields and clears nil values"] = function()
  local added = store.add({ file = "a.lua", line = 3, line_end = 5, type = "report", text = "broken" })

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
  local first = store.add({ file = "a.lua", line = 1, type = "consider", text = "one" })
  store.add({ file = "a.lua", line = 2, type = "consider", text = "two" })

  store.delete(first.id)

  local reloaded = store.load(true)
  eq(#reloaded, 1)
  eq(reloaded[1].text, "two")
end

T["get_at matches ranges, revisions and whole-file notes"] = function()
  store.add({ file = "a.lua", line = 4, line_end = 6, type = "report", text = "range" })
  store.add({ file = "a.lua", line = 5, rev = "abcdef12345", type = "report", text = "rev" })
  store.add({ file = "a.lua", line = 0, type = "context", text = "file" })

  eq(store.get_at("a.lua", 5).text, "range")
  eq(store.get_at("a.lua", 5, "abcdef12345").text, "rev")
  eq(store.get_at("a.lua", 0).text, "file")
  eq(store.get_at("a.lua", 7), nil)
end

T["archive moves the file and clears the store"] = function()
  store.add({ file = "a.lua", line = 1, type = "consider", text = "one" })
  local path = store.path()

  local archived = store.archive()

  eq(vim.uv.fs_stat(path), nil)
  eq(vim.uv.fs_stat(archived) ~= nil, true)
  eq(vim.startswith(archived, store.archive_dir()), true)
  eq(#store.all(), 0)
  eq(#store.load(true), 0)
end

---@return string[]
local function texts()
  return vim.tbl_map(function(annotation)
    return annotation.text
  end, store.load(true))
end

T["restore into an empty store takes the archive and removes it"] = function()
  store.add({ file = "a.lua", line = 1, type = "report", text = "one" })
  store.add({ file = "a.lua", line = 2, line_end = 3, type = "apply", text = "two" })
  local archived = store.archive()

  eq(store.restore(archived, "merge"), 2)

  eq(texts(), { "one", "two" })
  eq(store.load(true)[2].line_end, 3)
  eq(vim.uv.fs_stat(archived), nil)
  eq(store.archives(), {})
end

T["restore merge skips annotations the store already has"] = function()
  store.add({ file = "a.lua", line = 1, type = "report", text = "same" })
  store.add({ file = "a.lua", line = 2, type = "report", text = "archived" })
  local archived = store.archive()
  store.add({ file = "a.lua", line = 1, type = "report", text = "same" })
  store.add({ file = "a.lua", line = 1, type = "apply", text = "same" })

  eq(store.restore(archived, "merge"), 1)

  eq(texts(), { "same", "same", "archived" })
  eq(store.load(true)[2].type, "apply")
end

T["restore replace archives the store first"] = function()
  store.add({ file = "a.lua", line = 1, type = "report", text = "archived" })
  local archived = store.archive()
  store.add({ file = "a.lua", line = 2, type = "report", text = "live" })

  store.restore(archived, "replace")

  eq(texts(), { "archived" })
  local archives = store.archives()
  eq(#archives, 1)
  eq(store.read(archives[1])[1].text, "live")
end

T["restore rejects an unknown mode"] = function()
  store.add({ file = "a.lua", line = 1, type = "report", text = "one" })
  local archived = store.archive()

  MiniTest.expect.error(function()
    store.restore(archived, "append")
  end, "unknown restore mode")
  eq(vim.uv.fs_stat(archived) ~= nil, true)
end

--- Points HEAD of the repository in the working directory at a branch, without needing a commit.
---@param branch string
local function checkout(branch)
  vim.system({ "git", "symbolic-ref", "HEAD", "refs/heads/" .. branch }):wait()
end

T["per_branch keeps a store per branch and switches with HEAD"] = function()
  config.setup({ store = { per_branch = true } })
  checkout("feature")
  store.add({ file = "a.lua", line = 1, type = "report", text = "on feature" })
  local feature = store.path()

  checkout("main")
  eq(#store.all(), 0)
  eq(store.branch, "main")
  store.add({ file = "a.lua", line = 2, type = "report", text = "on main" })

  checkout("feature")
  eq(
    vim.tbl_map(function(a)
      return a.text
    end, store.all()),
    { "on feature" }
  )
  eq(store.path(), feature)
  eq(store.decode(feature).branch, "feature")
end

T["without per_branch every branch shares the store of the repository"] = function()
  checkout("feature")
  store.add({ file = "a.lua", line = 1, type = "report", text = "shared" })

  checkout("main")

  eq(#store.all(), 1)
  eq(store.branch, nil)
end

T["a detached HEAD uses the store of the repository"] = function()
  config.setup({ store = { per_branch = true } })
  vim.system({ "git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "commit", "-q", "--no-verify", "--allow-empty", "-m", "init" }):wait()
  local sha = vim.trim(vim.system({ "git", "rev-parse", "HEAD" }, { text = true }):wait().stdout)
  vim.system({ "git", "checkout", "-q", "--detach", sha }):wait()

  store.add({ file = "a.lua", line = 1, type = "report", text = "detached" })

  eq(store.branch, nil)
  eq(store.path(), store.file(store.root))
end

T["branches lists the other branches with notes and merges them without removing them"] = function()
  config.setup({ store = { per_branch = true } })
  checkout("empty")
  store.load()
  checkout("feature")
  store.add({ file = "a.lua", line = 1, type = "report", text = "from feature" })
  local feature = store.path()
  checkout("main")
  store.add({ file = "b.lua", line = 1, type = "report", text = "on main" })

  local branches = store.branches()
  eq(
    vim.tbl_map(function(b)
      return b.branch
    end, branches),
    { "feature" }
  )

  eq(store.merge(vim.deepcopy(branches[1].annotations)), 1)
  eq(store.merge(vim.deepcopy(branches[1].annotations)), 0)
  eq(#store.all(), 2)
  eq(vim.uv.fs_stat(feature) ~= nil, true)
  eq(#store.read(feature), 1)
end

T["branches includes the store of the repository taken before per_branch"] = function()
  store.add({ file = "a.lua", line = 1, type = "report", text = "before" })
  config.setup({ store = { per_branch = true } })
  checkout("main")
  store.load()

  local branches = store.branches()
  eq(#branches, 1)
  eq({ branches[1].branch, branches[1].path }, { nil, store.file(store.root) })
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

T["archives in the same second never overwrite each other"] = function()
  store.add({ type = "report", file = "a.lua", line = 1, text = "first" })
  local first = store.archive()
  store.add({ type = "report", file = "a.lua", line = 1, text = "second" })
  local second = store.archive()

  eq(first ~= second, true)
  eq(vim.uv.fs_stat(first) ~= nil and vim.uv.fs_stat(second) ~= nil, true)
end

T["maps the types of earlier versions to their replacements on load"] = function()
  store.add({ file = "a.lua", line = 1, type = "apply", text = "placeholder" })
  local path = store.path()
  vim.fn.writefile({
    vim.json.encode({
      annotations = {
        { id = "1", file = "a.lua", line = 1, type = "general", text = "wide", created_at = 0 },
        { id = "2", file = "a.lua", line = 2, type = "question", text = "why", created_at = 0 },
        { id = "3", file = "a.lua", line = 3, type = "rewrite", text = "same", created_at = 0 },
      },
    }),
  }, path)

  local loaded = vim.tbl_map(function(annotation)
    return { annotation.type, annotation.reach }
  end, store.load(true))

  eq(loaded, { { "apply", "pattern" }, { "discuss" }, { "rewrite" } })
end

return T
