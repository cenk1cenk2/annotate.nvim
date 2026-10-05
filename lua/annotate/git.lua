local M = {
  ---format is directory: repository root, false when the directory is outside a repository
  ---@type table<string, string|false>
  roots = {},
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
