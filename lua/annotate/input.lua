local M = {
  warned = false,
}

local config = require("annotate.config")

---@alias annotate.InputCallback fun(type_key: string?, text: string?)

---@param opts { type?: string, text?: string }
---@param callback annotate.InputCallback
function M.fallback(opts, callback)
  if not M.warned then
    M.warned = true
    vim.notify("snacks.nvim is not available, falling back to a single line input.", vim.log.levels.WARN, { title = config.options.notify.title })
  end

  local t = config.type(opts.type) or config.options.types[1]

  vim.ui.input({ prompt = ("%s %s: "):format(t.icon, t.name), default = opts.text }, function(text)
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

  if vim.fn.strdisplaywidth(title) > width then
    return ("‹ [%s %s] ›"):format(types[index].icon, types[index].name)
  end

  return title
end

--- Opens the annotation editor, calling back with the chosen type and text, or nils when cancelled or empty.
---@param opts { type?: string, text?: string }
---@param callback annotate.InputCallback
function M.open(opts, callback)
  local ok, snacks = pcall(require, "snacks")
  if not ok then
    return M.fallback(opts, callback)
  end

  local cfg = config.options.input
  local types = config.options.types
  local _, index = config.type(opts.type)
  index = index or 1

  local result = {}

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
      if cfg.markdown then
        pcall(vim.treesitter.start, self.buf, "markdown")
      end
    end,
    keys = {
      [cfg.keys.cycle] = {
        cfg.keys.cycle,
        function(self)
          index = index % #types + 1
          self:set_title(M.title(types, index, vim.api.nvim_win_get_width(self.win)), cfg.title_pos)
        end,
        mode = { "i", "n" },
        desc = "Cycle annotation type",
      },
      [cfg.keys.cycle_prev] = {
        cfg.keys.cycle_prev,
        function(self)
          index = (index - 2) % #types + 1
          self:set_title(M.title(types, index, vim.api.nvim_win_get_width(self.win)), cfg.title_pos)
        end,
        mode = { "i", "n" },
        desc = "Cycle annotation type backwards",
      },
      [cfg.keys.submit] = {
        cfg.keys.submit,
        function(self)
          local text = vim.trim(self:text())
          if text ~= "" then
            result = { types[index].key, text }
          end

          vim.cmd.stopinsert()
          self:close()
        end,
        mode = { "i", "n" },
        desc = "Submit annotation",
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

  win:set_title(M.title(types, index, vim.api.nvim_win_get_width(win.win)), cfg.title_pos)

  if not opts.text then
    vim.cmd.startinsert()
  end
end

return M
