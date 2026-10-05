local H = dofile("tests/helpers.lua")
local eq = MiniTest.expect.equality

local marks = require("annotate.marks")
local store = require("annotate.store")

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      require("annotate").setup()
      H.repo({ ["a.lua"] = { "one", "two", "three", "four", "five" } })
      vim.cmd.edit("a.lua")
    end,
    post_case = function()
      vim.cmd("silent! %bwipeout!")
    end,
  },
})

T["renders a sign and virtual text"] = function()
  store.add({ file = "a.lua", line = 2, type = "bug", text = "broken\nmore" })
  marks.render(0)

  local extmarks = vim.api.nvim_buf_get_extmarks(0, marks.ns, 0, -1, { details = true })
  eq(#extmarks, 1)
  eq(extmarks[1][2], 1)
  eq(extmarks[1][4].virt_text[1][1]:find("Bug: broken", 1, true) ~= nil, true)
end

T["leads the virtual text of a range with its lines"] = function()
  store.add({ file = "a.lua", line = 2, line_end = 4, type = "bug", text = "broken" })
  marks.render(0)

  local extmarks = vim.api.nvim_buf_get_extmarks(0, marks.ns, 0, -1, { details = true })
  eq(vim.startswith(extmarks[1][4].virt_text[1][1], "2-4  "), true)
end

T["shows a whole-file note above the first line led by file"] = function()
  store.add({ file = "a.lua", line = 0, type = "bug", text = "everything" })
  marks.render(0)

  local extmarks = vim.api.nvim_buf_get_extmarks(0, marks.ns, 0, -1, { details = true })
  eq(extmarks[1][4].virt_lines_above, true)
  eq(vim.startswith(extmarks[1][4].virt_lines[1][1][1], "file  "), true)
end

T["writes moved lines back to the store on write"] = function()
  local single = store.add({ file = "a.lua", line = 2, type = "bug", text = "single" })
  local range = store.add({ file = "a.lua", line = 3, line_end = 4, type = "suggestion", text = "range" })
  marks.render(0)

  vim.api.nvim_buf_set_lines(0, 0, 0, false, { "new 1", "new 2", "new 3" })
  vim.cmd("silent write")

  store.load(true)
  eq(store.get(single.id).line, 5)
  eq(store.get(range.id).line, 6)
  eq(store.get(range.id).line_end, 7)
end

T["skips annotations past the end of the buffer"] = function()
  store.add({ file = "a.lua", line = 40, type = "bug", text = "gone" })
  marks.render(0)

  eq(#vim.api.nvim_buf_get_extmarks(0, marks.ns, 0, -1, {}), 0)
end

return T
