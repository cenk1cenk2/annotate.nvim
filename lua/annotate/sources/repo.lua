---@class annotate.Source
local M = {}

M.name = "repo"

local git = require("annotate.git")

function M.match(bufnr)
  return vim.bo[bufnr].buftype == "" and git.relative(vim.api.nvim_buf_get_name(bufnr)) ~= nil
end

function M.resolve(bufnr, line1, line2)
  local file = git.relative(vim.api.nvim_buf_get_name(bufnr))
  if not file then
    return nil
  end

  return {
    file = file,
    line = line1,
    line_end = line2 > line1 and line2 or nil,
    context = require("annotate.sources.diffview").context(),
  }
end

return M
