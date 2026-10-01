local M = {
  sources = require("annotate.sources"),
  add = require("annotate.api").add,
  add_file = require("annotate.api").add_file,
  add_repository = require("annotate.api").add_repository,
  add_with_type = require("annotate.api").add_with_type,
  edit = require("annotate.api").edit,
  show = require("annotate.api").show,
  delete = require("annotate.api").delete,
  next = require("annotate.api").next,
  prev = require("annotate.api").prev,
  pick = require("annotate.api").pick,
  quickfix = require("annotate.api").quickfix,
  clear = require("annotate.api").clear,
  restore = require("annotate.api").restore,
  clear_archive = require("annotate.api").clear_archive,
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
