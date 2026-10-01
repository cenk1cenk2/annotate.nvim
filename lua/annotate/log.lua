local logger = vim.log.new and vim.log.new({ name = "annotate" })

local function noop()
  return nil
end

local M = logger and {
  trace = logger.trace,
  debug = logger.debug,
  info = logger.info,
  warn = logger.warn,
  error = logger.error,
} or {
  trace = noop,
  debug = noop,
  info = noop,
  warn = noop,
  error = noop,
}

---@param opts { level?: number }
function M.setup(opts)
  if logger and opts.level then
    vim.log.set_level(logger, opts.level)
  end
end

return M
