local M = {
  ns = vim.api.nvim_create_namespace("annotate"),
  ---format is bufnr: { annotation id: extmark id }
  ---@type table<integer, table<string, integer>>
  tracked = {},
}

local config = require("annotate.config")
local sources = require("annotate.sources")
local store = require("annotate.store")

---@param annotation annotate.Annotation
---@return annotate.Type
function M.type(annotation)
  return config.type(annotation.type) or { key = annotation.type, name = annotation.type, icon = "?", hl = "Comment", prompt = "" }
end

---@param t annotate.Type
---@return string
function M.line_hl(t)
  return ("Annotate%sLine"):format(t.key:gsub("^%l", string.upper))
end

function M.highlights()
  local blend = config.options.marks.blend
  local bg = vim.api.nvim_get_hl(0, { name = "Normal", link = false }).bg

  for _, t in ipairs(config.options.types) do
    local fg = vim.api.nvim_get_hl(0, { name = t.hl, link = false }).fg

    if fg and bg then
      local blended = 0
      for _, base in ipairs({ 0x10000, 0x100, 1 }) do
        blended = blended + math.floor(math.floor(fg / base) % 0x100 * blend + math.floor(bg / base) % 0x100 * (1 - blend)) * base
      end

      vim.api.nvim_set_hl(0, M.line_hl(t), { bg = blended, default = true })
    else
      vim.api.nvim_set_hl(0, M.line_hl(t), { link = "CursorLine", default = true })
    end
  end
end

--- Draws the annotations of the buffer's location and starts tracking their lines.
---@param bufnr integer
function M.render(bufnr)
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
  M.tracked[bufnr] = {}

  local location = sources.resolve(bufnr, 1, 1)
  if not location then
    return
  end

  local cfg = config.options.marks
  local count = vim.api.nvim_buf_line_count(bufnr)

  for _, annotation in ipairs(store.for_file(location.file, location.rev)) do
    local t = M.type(annotation)
    local virt_text = cfg.virtual_text and { { cfg.virtual_text_format(annotation, t), t.hl } } or nil

    if annotation.line == 0 then
      vim.api.nvim_buf_set_extmark(bufnr, M.ns, 0, 0, {
        priority = cfg.priority,
        sign_text = cfg.sign and t.icon or nil,
        sign_hl_group = cfg.sign and t.hl or nil,
        virt_lines = virt_text and { virt_text },
        virt_lines_above = virt_text and true,
      })
    elseif (annotation.line_end or annotation.line) <= count then
      M.tracked[bufnr][annotation.id] = vim.api.nvim_buf_set_extmark(bufnr, M.ns, annotation.line - 1, 0, {
        priority = cfg.priority,
        end_row = (annotation.line_end or annotation.line) - 1,
        sign_text = cfg.sign and t.icon or nil,
        sign_hl_group = cfg.sign and t.hl or nil,
        line_hl_group = cfg.line_highlight and M.line_hl(t) or nil,
        virt_text = virt_text,
        virt_text_pos = virt_text and "eol",
      })
    end
  end
end

--- Renders every buffer shown in a window.
function M.refresh()
  local seen = {}

  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local bufnr = vim.api.nvim_win_get_buf(win)
    if not seen[bufnr] then
      seen[bufnr] = true
      M.render(bufnr)
    end
  end
end

--- Writes the lines the tracked extmarks moved to back to the store.
---@param bufnr integer
---@return integer moved
function M.sync(bufnr)
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  local moved = 0

  for id, extmark in pairs(M.tracked[bufnr] or {}) do
    local annotation = store.get(id)
    local position = vim.api.nvim_buf_get_extmark_by_id(bufnr, M.ns, extmark, { details = true })

    if annotation and position[1] then
      local line = position[1] + 1
      local line_end = position[3].end_row and position[3].end_row + 1 or line

      if line ~= annotation.line or (line_end > line and line_end or nil) ~= annotation.line_end then
        annotation.line = line
        annotation.line_end = line_end > line and line_end or nil
        moved = moved + 1
      end
    end
  end

  if moved > 0 then
    store.save()
  end

  return moved
end

--- Removes all marks from every buffer.
function M.clear()
  M.tracked = {}

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
  end
end

function M.setup()
  local group = vim.api.nvim_create_augroup("annotate", { clear = true })

  M.highlights()

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = M.highlights,
  })

  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    callback = function(event)
      M.render(event.buf)
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "DiffviewDiffBufWinEnter",
    callback = M.refresh,
  })

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(event)
      M.sync(event.buf)
      M.render(event.buf)
    end,
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(event)
      M.tracked[event.buf] = nil
    end,
  })
end

return M
