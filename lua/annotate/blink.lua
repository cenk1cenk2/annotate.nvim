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
            insertText = ("`%s`"):format(symbol.name),
            kind = kinds[kind] or kinds.Reference,
            detail = path and vim.fn.fnamemodify(path, ":~:."),
          })
        end
      end
    end

    callback({ items = items, is_incomplete_forward = false, is_incomplete_backward = true })
  end)
end

return M
