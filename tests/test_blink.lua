local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

T["completes symbols from the annotated buffer's language servers"] = function()
  local origin = vim.api.nvim_create_buf(false, true)
  local input = vim.api.nvim_create_buf(false, true)
  vim.b[input].annotate_origin = origin

  local request = vim.lsp.buf_request_all
  vim.lsp.buf_request_all = function(bufnr, method, params, handler)
    eq({ bufnr, method, params.query }, { origin, "workspace/symbol", "res" })
    handler({
      [1] = { result = { { name = "resolve", kind = 12 }, { name = "resolve", kind = 12 }, { name = "Resolver", kind = 5 } } },
    })
  end

  local response
  require("annotate.blink").new():get_completions({
    bufnr = input,
    get_keyword = function()
      return "res"
    end,
  }, function(r)
    response = r
  end)
  vim.lsp.buf_request_all = request

  eq(
    vim.tbl_map(function(item)
      return item.insertText
    end, response.items),
    { "`resolve`", "`Resolver`" }
  )
  eq({ response.is_incomplete_forward, response.is_incomplete_backward }, { false, true })
end

T["returns nothing without an annotated buffer or a short keyword"] = function()
  local input = vim.api.nvim_create_buf(false, true)

  local response
  require("annotate.blink").new():get_completions({
    bufnr = input,
    get_keyword = function()
      return "resolve"
    end,
  }, function(r)
    response = r
  end)

  eq(response.items, {})
end

return T
