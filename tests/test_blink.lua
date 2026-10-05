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
      return { item.label, item.insertText }
    end, response.items),
    { { "resolve" }, { "Resolver" } }
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

---@param line string typed text
---@param start integer byte column where the keyword starts
---@param accepted string the line once blink replaced the keyword with the label
---@return string, integer
local function accept(line, start, accepted)
  vim.cmd.enew()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { line })

  local called = false
  local item = { label = "resolve", textEdit = { newText = "resolve", range = { start = { line = 0, character = start } } } }
  require("annotate.blink").new():execute({}, item, function()
    called = true
  end, function()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { accepted })
  end)
  eq(called, true)

  local result = { vim.api.nvim_get_current_line(), vim.api.nvim_win_get_cursor(0)[2] }
  vim.cmd("bwipeout!")

  return unpack(result)
end

T["wraps the accepted symbol in backticks and moves past them"] = function()
  eq({ accept("see res and", 4, "see resolve and") }, { "see `resolve` and", 13 })
end

T["does not double a backtick typed before or after the symbol"] = function()
  eq({ accept("see `res and", 5, "see `resolve and") }, { "see `resolve` and", 13 })
  eq({ accept("see `res` and", 5, "see `resolve` and") }, { "see `resolve` and", 13 })
end

return T
