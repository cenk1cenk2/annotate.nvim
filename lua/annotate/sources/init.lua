---@class annotate.Location
---@field file string path relative to the repository root
---@field line integer 1-based, 0 for a whole-file annotation
---@field line_end? integer
---@field rev? string nil for the working tree, otherwise a commit or a stage like `:0:`
---@field context? { left: string, right: string }

---@class annotate.Source
---@field name string
---@field match fun(bufnr: integer): boolean
---@field resolve fun(bufnr: integer, line1: integer, line2: integer): annotate.Location?

local M = {
  ---@type table<string, annotate.Source>
  registry = {
    repo = require("annotate.sources.repo"),
    diffview = require("annotate.sources.diffview"),
  },
}

local log = require("annotate.log")

--- Registers a source so it can be referenced by name in `config.sources`.
---@param source annotate.Source
---@return annotate.Source
function M.register(source)
  M.registry[source.name] = source

  return source
end

--- Sources in the configured order.
---@return annotate.Source[]
function M.list()
  return vim.tbl_map(function(source)
    if type(source) == "table" then
      return source
    end

    return M.registry[source] or error(("annotate: unknown source: %s"):format(source))
  end, require("annotate.config").options.sources)
end

--- First configured source that matches the buffer.
---@param bufnr integer
---@return annotate.Source?
function M.find(bufnr)
  for _, source in ipairs(M.list()) do
    if source.match(bufnr) then
      log.debug(("source matched: bufnr=%d source=%s"):format(bufnr, source.name))

      return source
    end
  end
end

--- Resolves a line range of a buffer to a location through the first matching source.
---@param bufnr integer
---@param line1 integer
---@param line2 integer
---@return annotate.Location?
function M.resolve(bufnr, line1, line2)
  local source = M.find(bufnr)

  return source and source.resolve(bufnr, line1, line2)
end

return M
