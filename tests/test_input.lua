local eq = MiniTest.expect.equality

local config = require("annotate.config")

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      config.setup({
        types = {
          { key = "a", name = "A", icon = "1", hl = "Comment", export = { prompt = "" } },
          { key = "b", name = "B", icon = "2", hl = "Comment", export = { prompt = "" } },
          { key = "c", name = "C", icon = "3", hl = "Comment", export = { prompt = "" } },
        },
      })
    end,
    post_case = function()
      package.loaded.snacks = nil
      config.setup()
      vim.cmd("silent! %bwipeout!")
    end,
  },
})

T["title lists every type with the current one in brackets"] = function()
  local types = config.options.types

  eq(config.resolve(config.options.input.title, types[2], config.options.input.keys, types, 2), "1 A · [2 B] · 3 C")
end

T["title falls back to the current type when it does not fit"] = function()
  local input = require("annotate.input")
  local types = config.options.types

  eq(input.title(types, 2, 40), "1 A · [2 B] · 3 C")
  eq(input.title(types, 2, 13), "… [2 B] · 3 C")
  eq(input.title(types, 2, 9), "… [2 B] …")
end

T["footer names both cycle keys"] = function()
  local types = config.options.types

  eq(config.resolve(config.options.input.footer, types[1], config.options.input.keys, types, 1), " <C-p>/<C-n> cycle  <C-s> submit  <C-q> close ")
end

---@param lines string[]
---@return integer
local function buffer(lines)
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].filetype = "lua"

  return bufnr
end

T["prefill fences the annotated lines with the filetype"] = function()
  local input = require("annotate.input")
  local bufnr = buffer({ "one", "two", "three" })

  eq(input.prefill(bufnr, { file = "a.lua", line = 2, line_end = 3 }), { "```lua", "two", "three", "```" })
  eq(input.prefill(bufnr, { file = "a.lua", line = 1 }), { "```lua", "one", "```" })
  eq(input.prefill(bufnr, { file = "a.lua", line = 0 }), nil)
  eq(input.prefill(bufnr, { line = 0 }), nil)
end

T["prefill fences lines holding backticks with a longer fence"] = function()
  eq(require("annotate.input").prefill(buffer({ "```lua" }), { file = "a.md", line = 1 }), { "````lua", "```lua", "````" })
end

--- Stands in for snacks.nvim with a real window whose key handlers the test calls.
---@return table
local function snacks()
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
      opts.on_buf(win)
      fake.win = win

      return win
    end,
  }

  return fake
end

---@param fake table
---@param key string
local function press(fake, key)
  fake.win.opts.keys[key][2](fake.win)
end

T["a prefill type opens with the selection and the cursor inside the block"] = function()
  config.setup({
    types = {
      { key = "a", name = "A", icon = "1", hl = "Comment", export = { prompt = "" } },
      { key = "r", name = "R", icon = "2", hl = "Comment", export = { prompt = "" }, prefill = "selection" },
    },
  })
  local fake = snacks()
  vim.api.nvim_set_current_buf(buffer({ "one", "two" }))

  require("annotate.input").open({ type = "r", location = { file = "a.lua", line = 2 } }, function() end)

  eq(vim.api.nvim_buf_get_lines(fake.win.buf, 0, -1, false), { "```lua", "two", "```" })
  eq(vim.api.nvim_win_get_cursor(fake.win.win), { 2, 0 })
  package.loaded.snacks = nil
end

T["cycling into a prefill type fills only an empty input"] = function()
  config.setup({
    types = {
      { key = "a", name = "A", icon = "1", hl = "Comment", export = { prompt = "" } },
      { key = "r", name = "R", icon = "2", hl = "Comment", export = { prompt = "" }, prefill = "selection" },
    },
  })
  local fake = snacks()
  vim.api.nvim_set_current_buf(buffer({ "one", "two" }))
  local keys = config.options.input.keys

  require("annotate.input").open({ type = "a", location = { file = "a.lua", line = 1, line_end = 2 } }, function() end)
  eq(vim.api.nvim_buf_get_lines(fake.win.buf, 0, -1, false), { "" })

  press(fake, keys.cycle)
  eq(vim.api.nvim_buf_get_lines(fake.win.buf, 0, -1, false), { "```lua", "one", "two", "```" })

  vim.api.nvim_buf_set_lines(fake.win.buf, 0, -1, false, { "mine" })
  press(fake, keys.cycle)
  press(fake, keys.cycle)
  eq(vim.api.nvim_buf_get_lines(fake.win.buf, 0, -1, false), { "mine" })
  vim.cmd.stopinsert()
  package.loaded.snacks = nil
end

return T
