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

--- Creates a directory outside any git repository with the given files and makes it the working directory.
---@param files? table<string, string[]>
---@return string
function M.dir(files)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  vim.env.GIT_CEILING_DIRECTORIES = vim.fs.dirname(dir)

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
      local win = { buf = bufnr, win = vim.api.nvim_open_win(bufnr, true, { relative = "editor", row = 1, col = 1, width = 60, height = 5, border = "single" }), opts = opts }
      function win.text()
        return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
      end
      function win.set_title() end
      function win.valid()
        return vim.api.nvim_win_is_valid(win.win)
      end
      function win.has_border()
        return true
      end
      function win.close()
        pcall(vim.api.nvim_win_close, win.win, true)
        if opts.on_close then
          opts.on_close()
        end
      end
      opts.on_buf(win)
      if opts.enter ~= false then
        fake.win = win
      else
        fake.panel = win
      end

      return win
    end,
  }

  return fake
end

--- Stands in for the snacks.nvim picker next to `M.snacks`, confirming in each pick the first item whose text contains the wanted string
--- in turn and leaving the picker open when none does. Returns the pickers it opened, each with its `opts` and `texts()` of its items.
---@param wanted string[]
---@return table[]
function M.picker(wanted)
  local opened = {}
  package.loaded.snacks = vim.tbl_extend("force", package.loaded.snacks or {}, {
    picker = {
      pick = function(opts)
        local picker = { opts = opts, title = opts.title, closed = false, refreshed = 0 }
        function picker.items()
          return opts.finder and opts.finder(opts) or opts.items
        end
        function picker.texts()
          return vim.tbl_map(function(item)
            return item.text
          end, picker.items())
        end
        function picker.close(self)
          self.closed = true
        end
        function picker.refresh(self)
          self.refreshed = self.refreshed + 1
        end
        table.insert(opened, picker)

        local want = table.remove(wanted, 1)
        for _, item in ipairs(want and picker.items() or {}) do
          if item.text:find(want, 1, true) then
            return opts.confirm(picker, item)
          end
        end
      end,
    },
  })

  return opened
end

---@param fake table
---@param key string
function M.press(fake, key)
  fake.win.opts.keys[key][2](fake.win)
end

return M
