---@class annotate.Source
local M = {}

M.name = "diffview"

--- Splits a `diffview://<gitdir>/<context>/<path>` buffer name.
---@param name string
---@return { gitdir: string, rev: string, path: string }?
function M.parse(name)
  local rest = name:match("^diffview://(.+)$")
  if not rest then
    return nil
  end

  local segments = vim.split(rest, "/", { plain = true })
  for i = 2, #segments - 1 do
    local segment = segments[i]

    if segment:match("^%x%x%x%x%x%x%x%x%x%x%x$") or segment:match("^:%d:$") or segment == "[custom]" then
      return {
        gitdir = table.concat(segments, "/", 1, i - 1),
        rev = segment,
        path = table.concat(segments, "/", i + 1),
      }
    end
  end
end

--- Revisions compared by the diffview view of the current tabpage.
---@return { left: string, right: string }?
function M.context()
  local ok, lib = pcall(require, "diffview.lib")
  if not ok then
    return nil
  end

  local view = lib.get_current_view()
  if not (view and view.left and view.right) then
    return nil
  end

  return {
    left = M.rev(view.left),
    right = M.rev(view.right),
  }
end

--- Formats a diffview revision the way diffview names its buffers.
---@param rev table diffview Rev
---@return string
function M.rev(rev)
  if rev.commit then
    return rev:abbrev(11)
  elseif rev.stage then
    return (":%d:"):format(rev.stage)
  end

  return tostring(rev)
end

function M.match(bufnr)
  return M.parse(vim.api.nvim_buf_get_name(bufnr)) ~= nil
end

function M.resolve(bufnr, line1, line2)
  local parsed = M.parse(vim.api.nvim_buf_get_name(bufnr))
  if not parsed then
    return nil
  end

  return {
    file = parsed.path,
    line = line1,
    line_end = line2 > line1 and line2 or nil,
    rev = parsed.rev,
    context = M.context(),
  }
end

return M
