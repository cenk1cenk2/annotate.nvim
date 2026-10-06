local M = {
  ---format is directory: repository root, false when the directory is outside a repository
  ---@type table<string, string|false>
  roots = {},
  ---format is repository root: its git directory, which is per worktree
  ---@type table<string, string|false>
  dirs = {},
}

--- Resolves the git root of a directory, with symlinks resolved.
---@param dir? string defaults to the current working directory
---@return string?
function M.root(dir)
  dir = dir or vim.fn.getcwd()

  if M.roots[dir] == nil then
    local result = vim.system({ "git", "-C", dir, "rev-parse", "--show-toplevel" }, { text = true }):wait()
    local root = vim.trim(result.stdout or "")

    M.roots[dir] = result.code == 0 and root ~= "" and (vim.uv.fs_realpath(root) or root) or false
  end

  return M.roots[dir] or nil
end

--- Git root of the current working directory, the working directory itself outside a repository.
---@return string
function M.workspace()
  local cwd = vim.fn.getcwd()

  return M.root(cwd) or vim.uv.fs_realpath(cwd) or cwd
end

--- Branch checked out in the repository of a directory, read from its HEAD, nil on a detached HEAD or outside a repository.
---@param dir? string defaults to the current working directory
---@return string?
function M.branch(dir)
  local root = M.root(dir)
  if not root then
    return nil
  end

  if M.dirs[root] == nil then
    local result = vim.system({ "git", "-C", root, "rev-parse", "--absolute-git-dir" }, { text = true }):wait()
    local gitdir = vim.trim(result.stdout or "")

    M.dirs[root] = result.code == 0 and gitdir ~= "" and gitdir or false
  end

  local file = M.dirs[root] and io.open(vim.fs.joinpath(M.dirs[root], "HEAD"), "r")
  if not file then
    return nil
  end

  local head = file:read("*a")
  file:close()

  return head:match("^ref: refs/heads/(.-)%s*$")
end

--- Path of a file relative to the workspace of the current working directory.
---@param path string
---@return string?
function M.relative(path)
  local root = M.workspace()
  if path == "" then
    return nil
  end

  local absolute = vim.uv.fs_realpath(vim.fn.fnamemodify(path, ":p")) or vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  if absolute:sub(1, #root + 1) ~= root .. "/" then
    return nil
  end

  return absolute:sub(#root + 2)
end

return M
