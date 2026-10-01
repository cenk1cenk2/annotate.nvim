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

--- Stands in for snacks.nvim with a real window whose key handlers the test calls.
---@return table
function M.snacks()
  local fake = {}
  package.loaded.snacks = {
    win = function(opts)
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, type(opts.text) == "table" and opts.text or vim.split(opts.text or "", "\n"))
      local win = { buf = bufnr, win = vim.api.nvim_open_win(bufnr, true, { relative = "editor", row = 1, col = 1, width = 60, height = 5 }), opts = opts }
      function win.text()
        return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
      end
      function win.set_title() end
      function win.close()
        pcall(vim.api.nvim_win_close, win.win, true)
        opts.on_close()
      end
      opts.on_buf(win)
      fake.win = win

      return win
    end,
  }

  return fake
end

---@param fake table
---@param key string
function M.press(fake, key)
  fake.win.opts.keys[key][2](fake.win)
end

return M
