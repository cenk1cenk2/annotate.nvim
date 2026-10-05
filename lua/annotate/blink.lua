--- blink.cmp source completing symbol names from the language servers of the annotated buffer.
---@class annotate.BlinkSource
local M = {}

---@return annotate.BlinkSource
function M.new()
  return setmetatable({}, { __index = M })
end

---@return boolean
function M:enabled()
  return vim.b.annotate_origin ~= nil
end

---@param context blink.cmp.Context
---@param callback fun(response?: blink.cmp.CompletionResponse)
---@return fun()?
function M:get_completions(context, callback)
  local origin = vim.b[context.bufnr].annotate_origin
  local keyword = context.get_keyword()

  if not origin or not vim.api.nvim_buf_is_valid(origin) or #keyword < 2 then
    callback({ items = {}, is_incomplete_forward = true, is_incomplete_backward = true })
    return
  end

  local kinds = vim.lsp.protocol.CompletionItemKind
  local symbol_kinds = vim.lsp.protocol.SymbolKind

  return vim.lsp.buf_request_all(origin, "workspace/symbol", { query = keyword }, function(results)
    local items = {}
    local seen = {}

    for _, result in pairs(results) do
      for _, symbol in ipairs(result.result or {}) do
        if not seen[symbol.name] then
          seen[symbol.name] = true
          local kind = symbol_kinds[symbol.kind]
          local path = symbol.location and symbol.location.uri and vim.uri_to_fname(symbol.location.uri)

          table.insert(items, {
            label = symbol.name,
            kind = kinds[kind] or kinds.Reference,
            detail = path and vim.fn.fnamemodify(path, ":~:."),
          })
        end
      end
    end

    callback({ items = items, is_incomplete_forward = false, is_incomplete_backward = true })
  end)
end

--- Inserts the symbol name, then wraps it in backticks unless they are already around it, so previews while selecting stay plain.
---@param item blink.cmp.CompletionItem
---@param callback fun()
---@param default fun()
function M:execute(_, item, callback, default)
  default()

  local range = item.textEdit.range
  local row, start = range.start.line, range.start.character
  local finish = start + #item.textEdit.newText
  local line = vim.api.nvim_buf_get_lines(0, row, row + 1, false)[1]
  local opened = line:sub(start, start) == "`"

  if line:sub(finish + 1, finish + 1) ~= "`" then
    vim.api.nvim_buf_set_text(0, row, finish, row, finish, { "`" })
  end
  if not opened then
    vim.api.nvim_buf_set_text(0, row, start, row, start, { "`" })
  end
  vim.api.nvim_win_set_cursor(0, { row + 1, finish + (opened and 1 or 2) })

  callback()
end

return M
