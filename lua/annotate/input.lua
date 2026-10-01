local M = {
  warned = false,
}

local config = require("annotate.config")

---@alias annotate.InputCallback fun(type_key: string?, text: string?)

---@class annotate.InputOptions
---@field type? string
---@field text? string
---@field title? string fixed title for free text that has no type, cycling is disabled; submitting calls back with a nil type and the text, empty included, cancelling with nils
---@field location? annotate.Location what the note is taken on, for the `prefill` of its type

---@param opts annotate.InputOptions
---@param callback annotate.InputCallback
function M.fallback(opts, callback)
  if not M.warned then
    M.warned = true
    vim.notify("snacks.nvim is not available, falling back to a single line input.", vim.log.levels.WARN, { title = config.options.notify.title })
  end

  local t = config.type(opts.type) or config.options.types[1]

  vim.ui.input({ prompt = opts.title and ("%s: "):format(opts.title) or ("%s %s: "):format(t.icon, t.name), default = opts.text }, function(text)
    if opts.title then
      return callback(nil, text and vim.trim(text))
    end

    text = text and vim.trim(text) or ""

    if text == "" then
      return callback(nil, nil)
    end

    callback(t.key, text)
  end)
end

--- Renders `input.title`, falling back to the current type alone when it is wider than the window.
---@param types annotate.Type[]
---@param index integer
---@param width integer
---@return string
function M.title(types, index, width)
  local cfg = config.options.input
  local title = config.resolve(cfg.title, types[index], cfg.keys, types, index)

  if vim.fn.strdisplaywidth(title) <= width then
    return title
  end

  local function label(i)
    return i == index and ("[%s %s]"):format(types[i].icon, types[i].name) or ("%s %s"):format(types[i].icon, types[i].name)
  end

  local shown = { label(index) }
  local left, right = index - 1, index + 1
  local function fits(candidate, first, last)
    local more = (first > 1 and 2 or 0) + (last < #types and 2 or 0)

    return vim.fn.strdisplaywidth(table.concat(candidate, " · ")) + more <= width
  end

  while left >= 1 or right <= #types do
    local grew = false

    for _, side in ipairs({ "right", "left" }) do
      if side == "right" and right <= #types then
        local candidate = vim.list_extend(vim.deepcopy(shown), { label(right) })
        if fits(candidate, left + 1, right) then
          shown, right, grew = candidate, right + 1, true
        end
      elseif side == "left" and left >= 1 then
        local candidate = vim.list_extend({ label(left) }, shown)
        if fits(candidate, left, right - 1) then
          shown, left, grew = candidate, left - 1, true
        end
      end
    end

    if not grew then
      break
    end
  end

  return ("%s%s%s"):format(left >= 1 and "… " or "", table.concat(shown, " · "), right <= #types and " …" or "")
end

--- The annotated lines of the buffer in a fenced block tagged with its filetype, nil for whole-file and repository notes.
---@param bufnr integer
---@param location? annotate.Location
---@return string[]?
function M.prefill(bufnr, location)
  if not (location and location.file and location.line > 0) then
    return nil
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, location.line - 1, location.line_end or location.line, false)
  local longest = 2
  for _, line in ipairs(lines) do
    for ticks in line:gmatch("`+") do
      longest = math.max(longest, #ticks)
    end
  end
  local fence = ("`"):rep(longest + 1)

  return vim.list_extend({ fence .. vim.bo[bufnr].filetype }, vim.list_extend(lines, { fence }))
end

--- Opens the annotation editor, calling back with the chosen type and text, or nils when cancelled or empty.
---@param opts annotate.InputOptions
---@param callback annotate.InputCallback
function M.open(opts, callback)
  local ok, snacks = pcall(require, "snacks")
  if not ok then
    return M.fallback(opts, callback)
  end

  local cfg = config.options.input
  local origin = vim.api.nvim_get_current_buf()
  local types = config.options.types
  local _, index = config.type(opts.type)
  index = index or 1

  local result = {}
  local prefill = M.prefill(origin, opts.location)

  ---@return boolean filled
  local function fill(self)
    if not prefill or types[index].prefill ~= "selection" or vim.trim(self:text()) ~= "" then
      return false
    end

    vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, prefill)
    vim.api.nvim_win_set_cursor(self.win, { 2, 0 })

    return true
  end

  local function title(self)
    self:set_title(opts.title and (" %s "):format(opts.title) or M.title(types, index, vim.api.nvim_win_get_width(self.win)), cfg.title_pos)
  end

  local function cycle(self, step)
    if opts.title then
      return
    end

    index = (index - 1 + step) % #types + 1
    title(self)
    fill(self)
  end

  local win = snacks.win({
    position = cfg.position,
    width = cfg.width,
    height = cfg.height,
    border = cfg.border,
    title = " ",
    title_pos = cfg.title_pos,
    footer = config.resolve(cfg.footer, types[index], cfg.keys, types, index),
    footer_pos = cfg.footer_pos,
    enter = true,
    text = opts.text,
    bo = { filetype = cfg.filetype, buftype = "nofile", bufhidden = "wipe" },
    wo = { wrap = true, linebreak = true },
    on_buf = function(self)
      vim.b[self.buf].annotate = true
      vim.b[self.buf].annotate_origin = origin
      if cfg.markdown then
        pcall(vim.treesitter.start, self.buf, "markdown")
      end
    end,
    keys = {
      [cfg.keys.cycle] = {
        cfg.keys.cycle,
        function(self)
          cycle(self, 1)
        end,
        mode = { "i", "n" },
        desc = "Cycle annotation type",
      },
      [cfg.keys.cycle_prev] = {
        cfg.keys.cycle_prev,
        function(self)
          cycle(self, -1)
        end,
        mode = { "i", "n" },
        desc = "Cycle annotation type backwards",
      },
      [cfg.keys.submit] = {
        cfg.keys.submit,
        function(self)
          local text = vim.trim(self:text())
          if opts.title then
            result = { nil, text }
          elseif text ~= "" then
            result = { types[index].key, text }
          end

          vim.cmd.stopinsert()
          self:close()
        end,
        mode = { "i", "n" },
        desc = "Submit annotation",
      },
      [cfg.keys.close] = {
        cfg.keys.close,
        function(self)
          vim.cmd.stopinsert()
          self:close()
        end,
        mode = { "i", "n" },
        desc = "Close annotation",
      },
      [cfg.keys.cancel] = {
        cfg.keys.cancel,
        function(self)
          self:close()
        end,
        mode = "n",
        desc = "Cancel annotation",
      },
    },
    on_close = function()
      vim.schedule(function()
        callback(result[1], result[2])
      end)
    end,
  })

  title(win)

  if not opts.text and not fill(win) then
    vim.cmd.startinsert()
  end
end

return M
