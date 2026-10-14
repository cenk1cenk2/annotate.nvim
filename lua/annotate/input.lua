local M = {
  warned = false,
}

local config = require("annotate.config")

---@alias annotate.InputCallback fun(type_key: string?, text: string?, reach: string?) reach is nil when it is the default of the type

---@class annotate.InputOptions
---@field type? string
---@field text? string
---@field reach? string
---@field title? string fixed title for free text that has no type, cycling is disabled; submitting calls back with a nil type and the text, empty included, cancelling with nils
---@field location? annotate.Location what the note is taken on, for the `prefill` of its type
---@field origin? integer buffer the note is taken on, defaults to the current one

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

    callback(t.key, text, vim.list_contains(t.reaches, opts.reach) and opts.reach ~= t.reaches[1] and opts.reach or nil)
  end)
end

--- Renders `input.title`, falling back to the current type alone when it is wider than the window.
---@param types annotate.Type[]
---@param index integer
---@param width integer
---@param reach? string defaults to the reach of the current type
---@return string
function M.title(types, index, width, reach)
  local cfg = config.options.input
  reach = reach or types[index].reaches[1]
  local title = config.resolve(cfg.title, types[index], cfg.keys, types, index, reach)

  if vim.fn.strdisplaywidth(title) <= width then
    return title
  end

  local function label(i)
    if i ~= index then
      return ("%s %s"):format(types[i].icon, types[i].name)
    end

    return ("[%s %s]%s"):format(types[i].icon, types[i].name, #types[i].reaches > 1 and (" (%s)"):format(reach) or "")
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

--- Markdown lines telling what a type asks for at a reach: the prompt the agent reads in the export, the one reviewers read on the forge, and its reaches.
---@param t annotate.Type
---@param reach string
---@return string[]
function M.describe(t, reach)
  local lines = { ("## %s %s (%s)"):format(t.icon, t.name, reach) }
  for _, kind in ipairs({ { "export", "Export" }, { "external", "Forge" } }) do
    local prompt = config.prompt(t, kind[1], reach)
    vim.list_extend(lines, { "", ("**%s**"):format(kind[2]), "" })
    vim.list_extend(lines, vim.split(prompt ~= "" and prompt or "_none_", "\n", { plain = true }))
  end

  if #t.reaches > 1 then
    local reaches = vim.tbl_map(function(r)
      return r == reach and ("[%s]"):format(r) or r
    end, t.reaches)
    vim.list_extend(lines, { "", ("Reaches: %s"):format(table.concat(reaches, " · ")) })
  end

  return lines
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
  local origin = opts.origin or vim.api.nvim_get_current_buf()
  local types = config.options.types
  local _, index = config.type(opts.type)
  index = index or 1
  local reach = vim.list_contains(types[index].reaches, opts.reach) and opts.reach or types[index].reaches[1]

  local result = {}
  local prefill = M.prefill(origin, opts.location)
  ---@type snacks.win?
  local panel

  --- Fills an empty input with the prefill on a prefill type, and empties an untouched prefill on any other type.
  ---@return boolean filled
  local function fill(self)
    if not prefill then
      return false
    end

    if types[index].prefill ~= "selection" then
      if self:text() == table.concat(prefill, "\n") then
        vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, {})
      end

      return false
    elseif vim.trim(self:text()) ~= "" then
      return false
    end

    vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, prefill)
    vim.api.nvim_win_set_cursor(self.win, { 2, 0 })

    return true
  end

  local function footer()
    return cfg.footer and config.resolve(cfg.footer, types[index], cfg.keys, types, index, reach)
  end

  --- Keys of `input.hints` the footer lists, leaving out those this input has no use for.
  local hints = vim
    .iter(cfg.hints)
    :filter(function(name)
      return not (
        opts.title and vim.list_contains({ "cycle", "cycle_prev", "reach", "describe", "selection" }, name)
        or name == "reach" and not vim.iter(types):any(function(t)
          return #t.reaches > 1
        end)
        or name == "selection" and not prefill
      )
    end)
    :map(function(name)
      return cfg.keys[name]
    end)
    :totable()

  local function title(self)
    self:set_title(opts.title and (" %s "):format(opts.title) or M.title(types, index, vim.api.nvim_win_get_width(self.win), reach), cfg.title_pos)
    local text = footer()
    if text and self.opts.footer ~= text and self:valid() and self:has_border() then
      self.opts.footer = text
      vim.api.nvim_win_set_config(self.win, { footer = text, footer_pos = cfg.footer_pos })
    end
  end

  --- Opens the description of the current type and reach below the input, replacing the one already open.
  local function describe(self)
    if panel then
      panel:close()
    end

    local lines = M.describe(types[index], reach)
    panel = snacks.win({
      relative = "win",
      win = self.win,
      row = vim.api.nvim_win_get_height(self.win) + 1,
      col = 0,
      width = vim.api.nvim_win_get_width(self.win),
      height = math.min(#lines, cfg.height),
      border = cfg.border,
      focusable = false,
      enter = false,
      text = lines,
      bo = { filetype = "markdown", modifiable = false },
      wo = { wrap = true, linebreak = true },
      on_buf = function(win)
        pcall(vim.treesitter.start, win.buf, "markdown")
      end,
    })
  end

  --- Shows the description again after the type or reach changed, when it is open.
  local function redescribe(self)
    if panel and panel:valid() then
      describe(self)
    end
  end

  local function cycle(self, step)
    if opts.title then
      return
    end

    index = (index - 1 + step) % #types + 1
    if not vim.list_contains(types[index].reaches, reach) then
      reach = types[index].reaches[1]
    end
    title(self)
    fill(self)
    redescribe(self)
  end

  local function widen(self)
    local reaches = types[index].reaches
    if opts.title or #reaches < 2 then
      return
    end

    reach = reaches[(vim.fn.index(reaches, reach) + 1) % #reaches + 1]
    title(self)
    redescribe(self)
  end

  --- Inserts the annotated lines as a fenced block below the cursor, or as the whole input when it is empty.
  local function selection(self)
    if not prefill then
      return
    end

    if vim.trim(self:text()) == "" then
      vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, prefill)
      vim.api.nvim_win_set_cursor(self.win, { #prefill, 0 })
    else
      local row = vim.api.nvim_win_get_cursor(self.win)[1]
      vim.api.nvim_buf_set_lines(self.buf, row, row, false, prefill)
      vim.api.nvim_win_set_cursor(self.win, { row + #prefill, 0 })
    end
  end

  local win = snacks.win({
    position = cfg.position,
    width = cfg.width,
    height = cfg.height,
    border = cfg.border,
    title = " ",
    title_pos = cfg.title_pos,
    footer = footer() or nil,
    footer_pos = cfg.footer_pos,
    footer_keys = not cfg.footer and #hints > 0 and hints or nil,
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
        desc = "Next type",
      },
      [cfg.keys.cycle_prev] = {
        cfg.keys.cycle_prev,
        function(self)
          cycle(self, -1)
        end,
        mode = { "i", "n" },
        desc = "Previous type",
      },
      [cfg.keys.reach] = {
        cfg.keys.reach,
        widen,
        mode = { "i", "n" },
        desc = "Next reach",
      },
      [cfg.keys.describe] = {
        cfg.keys.describe,
        function(self)
          if opts.title then
            return
          end

          if panel and panel:valid() then
            panel:close()
          else
            describe(self)
          end
        end,
        mode = { "i", "n" },
        desc = "Describe type",
      },
      [cfg.keys.selection] = {
        cfg.keys.selection,
        selection,
        mode = { "i", "n" },
        desc = "Insert selection",
      },
      [cfg.keys.submit] = {
        cfg.keys.submit,
        function(self)
          local text = vim.trim(self:text())
          if opts.title then
            result = { nil, text }
          elseif text ~= "" then
            result = { types[index].key, text, reach ~= types[index].reaches[1] and reach or nil }
          end

          vim.cmd.stopinsert()
          self:close()
        end,
        mode = { "i", "n" },
        desc = "Submit",
      },
      [cfg.keys.close] = {
        cfg.keys.close,
        function(self)
          vim.cmd.stopinsert()
          self:close()
        end,
        mode = { "i", "n" },
        desc = "Close",
      },
      [cfg.keys.cancel] = {
        cfg.keys.cancel,
        function(self)
          self:close()
        end,
        mode = "n",
        desc = "Cancel",
      },
    },
    on_close = function()
      if panel then
        panel:close()
      end
      vim.schedule(function()
        callback(result[1], result[2], result[3])
      end)
    end,
  })

  title(win)

  if not opts.text and not fill(win) then
    vim.cmd.startinsert()
  end
end

return M
