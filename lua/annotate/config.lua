local M = {}

---@class annotate.Type
---@field key string
---@field name string
---@field icon string
---@field hl string
---@field prompt string

---@class annotate.InputKeys
---@field cycle string
---@field submit string
---@field cancel string

---@class annotate.InputConfig
---@field width number
---@field height number
---@field border string
---@field keys annotate.InputKeys

---@alias annotate.ExportTarget "file"|"clipboard"|"both"|fun(markdown: string, annotations: annotate.Annotation[])

---@class annotate.ExportConfig
---@field to annotate.ExportTarget
---@field prompt string
---@field clipboard_message string

---@class annotate.Config
---@field log_level? number
---@field types? annotate.Type[]
---@field sources? (string|annotate.Source)[]
---@field input? annotate.InputConfig
---@field export? annotate.ExportConfig

---@type annotate.Config
local defaults = {
  log_level = vim.log.levels.INFO,
  types = {
    {
      key = "general",
      name = "General",
      icon = "",
      hl = "DiagnosticInfo",
      prompt = "A note about the repository as a whole, not only the line it is pinned to. Treat the location as one example: find every place the same thing applies, handle it there too, and list where you applied it.",
    },
    {
      key = "praise",
      name = "Praise",
      icon = "",
      hl = "DiagnosticOk",
      prompt = "This is the pattern I want. Keep it, and treat it as the reference: look for places that drift from it, bring them in line, and list each one you changed.",
    },
    {
      key = "suggestion",
      name = "Suggestion",
      icon = "",
      hl = "DiagnosticWarn",
      prompt = "An idea worth weighing, not an order. Evaluate it honestly against the surrounding code: apply it if it holds up, and if you decide against it, say why in a sentence or two. Never skip it silently.",
    },
    {
      key = "bug",
      name = "Bug",
      icon = "",
      hl = "DiagnosticError",
      prompt = "This is, or will cause, a bug, and the note says how it shows up. Confirm the failure by reproducing it or reasoning it through from the code, fix the cause rather than the symptom, and add a test that fails without the fix whenever the code is testable.",
    },
    {
      key = "question",
      name = "Question",
      icon = "",
      hl = "DiagnosticHint",
      prompt = "A question for us to settle together, not for you to answer alone. Change no code for it. Give your read, the options and their trade-offs, recommend one, and wait for my answer before acting on anything it decides.",
    },
    {
      key = "context",
      name = "Context",
      icon = "",
      hl = "Comment",
      prompt = "Background for the other notes: why the code is this way, a constraint, or history. Do not act on it by itself; use it while you work through the rest.",
    },
  },
  sources = { "diffview", "repo" },
  input = {
    width = 80,
    height = 10,
    border = "rounded",
    keys = {
      cycle = "<C-n>",
      submit = "<C-s>",
      cancel = "q",
    },
  },
  export = {
    to = "both",
    prompt = "These are my review notes on this repository. Each section below groups one kind of note, and its line under Description says what I expect for that kind. Work through every item: re-read the code at each location before acting, since lines may have moved since I wrote the note, and do what the note's type asks. Questions are for us to settle together, so bring them back to me instead of deciding them yourself. When you finish, report back item by item: what you changed, where you applied a general or praise note, what you decided on each suggestion and why, and the questions still waiting on me.",
    clipboard_message = "Here are my review notes for this repository. Read the attached file and work through every item as it describes.",
  },
}

---@type annotate.Config
---@diagnostic disable-next-line: missing-fields
M.options = vim.deepcopy(defaults)

---@param config? annotate.Config
---@return annotate.Config
function M.setup(config)
  M.options = vim.tbl_deep_extend("force", {}, defaults, config or {})

  return M.options
end

--- Looks up a configured annotation type by its key.
---@param key string
---@return annotate.Type?, integer?
function M.type(key)
  for index, t in ipairs(M.options.types) do
    if t.key == key then
      return t, index
    end
  end
end

return M
