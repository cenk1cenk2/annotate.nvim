local M = {}

M.defaults = {
  retries = 3,
  timeout = 1000,
}

function M.fetch(url, opts)
  opts = vim.tbl_extend("force", M.defaults, opts or {})
  local attempt = 0
  while attempt < opts.retries do
    attempt = attempt + 1
    local ok, result = pcall(vim.system, { "curl", "-s", url }, { timeout = opts.timeout })
    if ok then
      return result:wait().stdout
    end
  end

  return nil
end

function M.parse(body)
  return vim.json.decode(body)
end

return M
