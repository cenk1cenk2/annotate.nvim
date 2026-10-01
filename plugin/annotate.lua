if vim.g.loaded_annotate then
  return
end
vim.g.loaded_annotate = true

local subcommands = {
  add = function(cmd)
    require("annotate").add(cmd.range > 0 and { line1 = cmd.line1, line2 = cmd.line2 } or nil)
  end,
  file = function()
    require("annotate").add_file()
  end,
  edit = function()
    require("annotate").edit()
  end,
  delete = function()
    require("annotate").delete()
  end,
  next = function()
    require("annotate").next()
  end,
  prev = function()
    require("annotate").prev()
  end,
  pick = function()
    require("annotate").pick()
  end,
  quickfix = function()
    require("annotate").quickfix()
  end,
  export = function(cmd)
    require("annotate").export({ to = cmd.fargs[2] })
  end,
  preview = function()
    require("annotate").preview()
  end,
  clear = function()
    require("annotate").clear()
  end,
}

vim.api.nvim_create_user_command("Annotate", function(cmd)
  local subcommand = subcommands[cmd.fargs[1]]
  if not subcommand then
    return vim.notify(("Unknown subcommand: %s"):format(cmd.fargs[1]), vim.log.levels.ERROR, { title = "annotate" })
  end

  subcommand(cmd)
end, {
  nargs = "+",
  range = true,
  desc = "Annotate lines of a repository and export the notes",
  complete = function(arglead, line)
    local args = vim.split(line, "%s+", { trimempty = true })
    local candidates = vim.tbl_keys(subcommands)
    if #args > 2 or #args == 2 and arglead == "" then
      candidates = args[2] == "export" and { "file", "clipboard", "both" } or {}
    end

    table.sort(candidates)

    return vim.tbl_filter(function(candidate)
      return vim.startswith(candidate, arglead)
    end, candidates)
  end,
})
