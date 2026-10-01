---@class annotate.Annotation: annotate.Location
---@field id string
---@field type string
---@field text string
---@field created_at integer
---@field posted? annotate.Posted[] where `publish` posted the annotation

local M = {
  ---@type string?
  root = nil,
  ---@type annotate.Annotation[]
  annotations = {},
  ---where `publish` posted the type legend
  ---@type { posted?: annotate.Posted[] }
  legend = {},
}

local log = require("annotate.log")
local git = require("annotate.git")

---@return string
function M.dir()
  return require("annotate.config").options.store.dir
end

---@return string
function M.archive_dir()
  return vim.fs.joinpath(M.dir(), "archive")
end

---@param root string
---@return string
function M.hash(root)
  return vim.fn.sha256(root):sub(1, 16)
end

--- Store file for the repository of the current working directory.
---@return string
function M.path()
  local root = git.root() or error(("annotate: not inside a git repository: %s"):format(vim.fn.getcwd()))

  return vim.fs.joinpath(M.dir(), M.hash(root) .. ".json")
end

--- Decoded content of a store file, empty when it does not exist.
---@param path string
---@return { annotations?: annotate.Annotation[], legend?: { posted?: annotate.Posted[] } }
function M.decode(path)
  local file = io.open(path, "r")
  if not file then
    return {}
  end

  local content = file:read("*a")
  file:close()

  if content == "" then
    return {}
  end

  return vim.json.decode(content, { luanil = { object = true, array = true } })
end

---@param path string
---@return annotate.Annotation[]
function M.read(path)
  return M.decode(path).annotations or {}
end

--- Loads the annotations of the current repository, reading the file only when the repository changed.
---@param force? boolean
---@return annotate.Annotation[]
function M.load(force)
  local root = git.root() or error(("annotate: not inside a git repository: %s"):format(vim.fn.getcwd()))
  if not force and M.root == root then
    return M.annotations
  end

  M.root = root

  local path = M.path()
  local content = M.decode(path)
  M.annotations = content.annotations or {}
  M.legend = content.legend or {}

  log.debug(("store loaded: path=%s #annotations=%d"):format(path, #M.annotations))

  vim.schedule(M.prune)

  return M.annotations
end

function M.save()
  M.load()

  local path = M.path()
  vim.fn.mkdir(vim.fs.dirname(path), "p")

  local file = assert(io.open(path, "w"))
  file:write(vim.json.encode({ root = M.root, annotations = M.annotations, legend = next(M.legend) and M.legend or nil }))
  file:close()

  log.debug(("store saved: path=%s #annotations=%d"):format(path, #M.annotations))
end

---@param annotation annotate.Location|{ type: string, text: string }
---@return annotate.Annotation
function M.add(annotation)
  M.load()

  local created = vim.tbl_extend("force", annotation, {
    id = ("%x%04x"):format(os.time(), math.random(0, 0xffff)),
    created_at = os.time(),
  })
  table.insert(M.annotations, created)
  M.save()

  return created
end

---@param id string
---@return annotate.Annotation?
function M.get(id)
  for _, annotation in ipairs(M.load()) do
    if annotation.id == id then
      return annotation
    end
  end
end

---@param id string
---@param fields table
---@return annotate.Annotation
function M.update(id, fields)
  local annotation = M.get(id) or error(("annotate: no annotation with id: %s"):format(id))

  for key, value in pairs(fields) do
    annotation[key] = value ~= vim.NIL and value or nil
  end
  M.save()

  return annotation
end

---@param id string
---@return annotate.Annotation?
function M.delete(id)
  for index, annotation in ipairs(M.load()) do
    if annotation.id == id then
      table.remove(M.annotations, index)
      M.save()

      return annotation
    end
  end
end

---@return annotate.Annotation[]
function M.all()
  return M.load()
end

--- Annotations on a file at a revision, nil revision being the working tree.
---@param file string
---@param rev? string
---@return annotate.Annotation[]
function M.for_file(file, rev)
  return vim.tbl_filter(function(annotation)
    return annotation.file == file and annotation.rev == rev
  end, M.load())
end

--- Annotation covering a line, a line of 0 only matching whole-file annotations.
---@param file string
---@param line integer
---@param rev? string
---@return annotate.Annotation?
function M.get_at(file, line, rev)
  for _, annotation in ipairs(M.for_file(file, rev)) do
    if line == 0 and annotation.line == 0 or annotation.line > 0 and line >= annotation.line and line <= (annotation.line_end or annotation.line) then
      return annotation
    end
  end
end

--- Moves the store file into the archive and clears the annotations.
---@return string? archived path, nil when nothing was stored
function M.archive()
  M.load()

  local path = M.path()
  M.annotations = {}
  M.legend = {}

  if not vim.uv.fs_stat(path) then
    return nil
  end

  vim.fn.mkdir(M.archive_dir(), "p")
  local stem = vim.fs.joinpath(M.archive_dir(), ("%s-%s"):format(M.hash(M.root), os.date("%Y%m%d-%H%M%S")))
  local target, n = stem .. ".json", 1
  while vim.uv.fs_stat(target) do
    target, n = ("%s-%d.json"):format(stem, n), n + 1
  end
  assert(vim.uv.fs_rename(path, target))

  log.info(("store archived: path=%s target=%s"):format(path, target))

  return target
end

--- Archives every annotation as a snapshot and keeps only the given ones in the store.
---@param keep annotate.Annotation[]
---@return string? archived path, nil when nothing was stored
function M.split(keep)
  local legend = M.legend
  local archived = M.archive()
  M.annotations = vim.deepcopy(keep)
  M.legend = legend
  M.save()

  return archived
end

--- Archives of the current repository, newest first.
---@return string[]
function M.archives()
  M.load()

  local archives = vim.fn.glob(vim.fs.joinpath(M.archive_dir(), M.hash(M.root) .. "-*.json"), false, true)
  table.sort(archives, function(a, b)
    return a > b
  end)

  return archives
end

--- Restores an archive into the store and removes it from the archive.
--- An empty store takes the archive as is, otherwise `merge` appends the annotations it does not have yet and `replace` archives the store first.
---@param path string
---@param mode "merge"|"replace"
---@return integer restored
function M.restore(path, mode)
  if mode ~= "merge" and mode ~= "replace" then
    error(("annotate: unknown restore mode: %s"):format(mode))
  end

  M.load()

  local restored = M.read(path)
  assert(os.remove(path))

  if mode == "replace" and #M.annotations > 0 then
    M.archive()
  end

  local count = 0
  for _, annotation in ipairs(restored) do
    local duplicate = vim.iter(M.annotations):any(function(existing)
      return existing.file == annotation.file
        and existing.line == annotation.line
        and existing.line_end == annotation.line_end
        and existing.rev == annotation.rev
        and existing.type == annotation.type
        and existing.text == annotation.text
    end)

    if not duplicate then
      table.insert(M.annotations, annotation)
      count = count + 1
    end
  end
  M.save()

  log.info(("archive restored: path=%s mode=%s #restored=%d"):format(path, mode, count))

  return count
end

--- Permanently removes archives.
---@param paths string[]
function M.remove_archives(paths)
  for _, path in ipairs(paths) do
    assert(os.remove(path))
    log.debug(("archive removed: path=%s"):format(path))
  end
end

--- Removes archives older than `archive_days`.
function M.prune()
  local now = os.time()

  for _, path in ipairs(vim.fn.glob(vim.fs.joinpath(M.archive_dir(), "*.json"), false, true)) do
    local stat = vim.uv.fs_stat(path)
    if stat and now - stat.mtime.sec > require("annotate.config").options.archive_days * 24 * 60 * 60 then
      os.remove(path)
      log.debug(("archive pruned: path=%s"):format(path))
    end
  end
end

return M
