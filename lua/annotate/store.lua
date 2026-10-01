---@class annotate.Annotation: annotate.Location
---@field id string
---@field type string
---@field text string
---@field created_at integer

local M = {
  ---@type string?
  root = nil,
  ---@type annotate.Annotation[]
  annotations = {},
}

local log = require("annotate.log")
local git = require("annotate.git")

local ARCHIVE_EXPIRY = 30 * 24 * 60 * 60

---@return string
function M.dir()
  return vim.fs.joinpath(vim.fn.stdpath("data"), "annotate")
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

--- Loads the annotations of the current repository, reading the file only when the repository changed.
---@param force? boolean
---@return annotate.Annotation[]
function M.load(force)
  local root = git.root() or error(("annotate: not inside a git repository: %s"):format(vim.fn.getcwd()))
  if not force and M.root == root then
    return M.annotations
  end

  M.root = root
  M.annotations = {}

  local path = M.path()
  local file = io.open(path, "r")
  if file then
    local content = file:read("*a")
    file:close()

    if content ~= "" then
      M.annotations = vim.json.decode(content, { luanil = { object = true, array = true } }).annotations or {}
    end
  end

  log.debug(("store loaded: path=%s #annotations=%d"):format(path, #M.annotations))

  vim.schedule(M.prune)

  return M.annotations
end

function M.save()
  M.load()

  local path = M.path()
  vim.fn.mkdir(vim.fs.dirname(path), "p")

  local file = assert(io.open(path, "w"))
  file:write(vim.json.encode({ root = M.root, annotations = M.annotations }))
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

  if not vim.uv.fs_stat(path) then
    return nil
  end

  vim.fn.mkdir(M.archive_dir(), "p")
  local target = vim.fs.joinpath(M.archive_dir(), ("%s-%s.json"):format(M.hash(M.root), os.date("%Y%m%d-%H%M%S")))
  assert(vim.uv.fs_rename(path, target))

  log.info(("store archived: path=%s target=%s"):format(path, target))

  return target
end

--- Removes archives older than 30 days.
function M.prune()
  local now = os.time()

  for _, path in ipairs(vim.fn.glob(vim.fs.joinpath(M.archive_dir(), "*.json"), false, true)) do
    local stat = vim.uv.fs_stat(path)
    if stat and now - stat.mtime.sec > ARCHIVE_EXPIRY then
      os.remove(path)
      log.debug(("archive pruned: path=%s"):format(path))
    end
  end
end

return M
