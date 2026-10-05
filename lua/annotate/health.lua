local M = {}

function M.check()
  local health = vim.health

  health.start("annotate")

  if vim.fn.has("nvim-0.11") == 1 then
    health.ok(("Neovim %s"):format(tostring(vim.version())))
  else
    health.error(("Neovim 0.11 or newer is required, found %s"):format(tostring(vim.version())))
  end

  if vim.log.new then
    health.ok(("File logging through vim.log: %s"):format(vim.fs.joinpath(vim.fn.stdpath("log"), "annotate.log")))
  else
    health.info("vim.log is not available (Neovim 0.13+), logging is disabled")
  end

  if pcall(require, "snacks") then
    health.ok("snacks.nvim is available")
  else
    health.warn("snacks.nvim is not available, input falls back to vim.ui.input and the picker to vim.ui.select")
  end

  if vim.fn.executable("git") == 1 then
    health.ok("git is available")

    local root = require("annotate.git").root()
    if root then
      health.ok(("Repository: %s, store: %s"):format(root, require("annotate.store").path()))
    else
      health.info(("The working directory is not inside a git repository, publishing is inactive: %s, store: %s"):format(vim.fn.getcwd(), require("annotate.store").path()))
    end
  else
    health.error("git is not available")
  end

  local external = require("annotate.config").options.external
  for _, cli in ipairs({ external.gitlab_cli, external.github_cli }) do
    if vim.fn.executable(cli) == 1 then
      health.ok(("%s is available for publishing"):format(cli))
    else
      health.info(("%s is not available, publishing to its forge is inactive"):format(cli))
    end
  end

  if pcall(require, "diffview.lib") then
    health.ok("diffview is available")
  else
    health.info("diffview is not available, the diffview source is inactive")
  end
end

return M
