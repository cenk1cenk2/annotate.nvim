local root = vim.fn.getcwd()
vim.opt.rtp:prepend(root)
vim.opt.rtp:append(vim.fs.joinpath(root, "deps", "mini.test"))

local clipboard = {}
vim.g.clipboard = {
  name = "test",
  copy = {
    ["+"] = function(lines)
      clipboard["+"] = lines
    end,
    ["*"] = function(lines)
      clipboard["*"] = lines
    end,
  },
  paste = {
    ["+"] = function()
      return clipboard["+"] or {}
    end,
    ["*"] = function()
      return clipboard["*"] or {}
    end,
  },
}

require("mini.test").setup()
