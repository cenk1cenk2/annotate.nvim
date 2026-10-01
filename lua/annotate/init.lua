local M = {
  sources = require("annotate.sources"),
  add = require("annotate.api").add,
  add_file = require("annotate.api").add_file,
  edit = require("annotate.api").edit,
  delete = require("annotate.api").delete,
  next = require("annotate.api").next,
  prev = require("annotate.api").prev,
  pick = require("annotate.api").pick,
  quickfix = require("annotate.api").quickfix,
  clear = require("annotate.api").clear,
  export = require("annotate.export").export,
  preview = require("annotate.export").preview,
}

--- Configures the annotate plugin.
---@param config? annotate.Config
function M.setup(config)
  local c = require("annotate.config").setup(config)

  require("annotate.log").setup({ level = c.log_level })
  require("annotate.marks").setup()
end

return M
