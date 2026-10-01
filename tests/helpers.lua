local M = {}

--- Creates a git repository with the given files and makes it the working directory.
---@param files? table<string, string[]>
---@return string
function M.repo(files)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  vim.system({ "git", "init", "-q", dir }):wait()

  for name, lines in pairs(files or {}) do
    vim.fn.writefile(lines, vim.fs.joinpath(dir, name))
  end

  vim.fn.chdir(dir)

  return vim.uv.fs_realpath(dir)
end

return M
