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

---@alias annotate.InputFormat string|fun(type: annotate.Type, keys: annotate.InputKeys): string

---@class annotate.InputConfig
---@field width number
---@field height number
---@field border string
---@field position string
---@field title annotate.InputFormat
---@field title_pos string
---@field footer annotate.InputFormat
---@field footer_pos string
---@field filetype string
---@field markdown boolean
---@field keys annotate.InputKeys

---@class annotate.StoreConfig
---@field dir string

---@class annotate.MarksConfig
---@field sign boolean
---@field line_highlight boolean
---@field virtual_text boolean
---@field virtual_text_format fun(annotation: annotate.Annotation, type: annotate.Type): string
---@field blend number
---@field priority integer

---@class annotate.ShowConfig
---@field border? string nil inherits input.border
---@field max_width integer
---@field max_height integer
---@field focusable boolean

---@class annotate.PickerKeys
---@field edit string|false
---@field delete string|false
---@field delete_all string|false
---@field type string|false

---@class annotate.PickerForce
---@field delete boolean
---@field delete_all boolean

---@class annotate.PickerConfig
---@field backend? "snacks"|"select" nil picks snacks when available
---@field title string
---@field keys annotate.PickerKeys
---@field force annotate.PickerForce

---@class annotate.QuickfixConfig
---@field title string
---@field open boolean

---@class annotate.NotifyConfig
---@field title string

---@alias annotate.ExportTarget "file"|"clipboard"|"both"|fun(markdown: string, annotations: annotate.Annotation[])

---@class annotate.ExportHeadings
---@field description string
---@field compared string

---@class annotate.ExportConfig
---@field to annotate.ExportTarget
---@field prompt string
---@field clipboard_message string
---@field dir string
---@field filename string|fun(repository: string): string
---@field headings annotate.ExportHeadings
---@field separator string
---@field label fun(type: annotate.Type): string
---@field format? fun(annotations: annotate.Annotation[], opts: annotate.ExportOptions, config: annotate.Config): string

---@class annotate.Config
---@field log_level? number
---@field types? annotate.Type[]
---@field default_type? string
---@field sources? (string|annotate.Source)[]
---@field archive_days? number
---@field confirm_delete? boolean
---@field store? annotate.StoreConfig
---@field marks? annotate.MarksConfig
---@field input? annotate.InputConfig
---@field show? annotate.ShowConfig
---@field picker? annotate.PickerConfig
---@field quickfix? annotate.QuickfixConfig
---@field notify? annotate.NotifyConfig
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
  default_type = nil,
  sources = { "diffview", "repo" },
  archive_days = 30,
  confirm_delete = true,
  store = {
    dir = vim.fs.joinpath(vim.fn.stdpath("data"), "annotate"),
  },
  marks = {
    sign = true,
    line_highlight = true,
    virtual_text = true,
    virtual_text_format = function(annotation, t)
      return ("%s %s: %s"):format(t.icon, t.name, vim.split(annotation.text, "\n", { plain = true })[1])
    end,
    blend = 0.15,
    priority = 4096,
  },
  input = {
    width = 80,
    height = 10,
    border = "rounded",
    position = "float",
    title = function(t)
      return (" %s %s "):format(t.icon, t.name)
    end,
    title_pos = "center",
    footer = function(_, keys)
      return (" %s cycle  %s submit  %s cancel "):format(keys.cycle, keys.submit, keys.cancel)
    end,
    footer_pos = "center",
    filetype = "annotate",
    markdown = true,
    keys = {
      cycle = "<C-n>",
      submit = "<C-s>",
      cancel = "q",
    },
  },
  show = {
    border = nil,
    max_width = 80,
    max_height = 20,
    focusable = true,
  },
  picker = {
    backend = nil,
    title = "Annotations",
    keys = {
      edit = "<C-e>",
      delete = "<C-d>",
      delete_all = "<C-x>",
      type = "<C-t>",
    },
    force = {
      delete = false,
      delete_all = false,
    },
  },
  quickfix = {
    title = "annotate",
    open = true,
  },
  notify = {
    title = "annotate",
  },
  export = {
    to = "both",
    prompt = "These are my review notes on this repository. Each section below groups one kind of note, and its line under Description says what I expect for that kind. Work through every item: re-read the code at each location before acting, since lines may have moved since I wrote the note, and do what the note's type asks. Questions are for us to settle together, so bring them back to me instead of deciding them yourself. When you finish, report back item by item: what you changed, where you applied a general or praise note, what you decided on each suggestion and why, and the questions still waiting on me.",
    clipboard_message = "Here are my review notes for this repository. Read the attached file and work through every item as it describes.",
    dir = vim.fs.joinpath(vim.uv.os_tmpdir(), "annotate"),
    filename = function(repository)
      return ("%s-%s.md"):format(repository, os.date("%Y%m%d-%H%M%S"))
    end,
    headings = {
      description = "Description",
      compared = "Compared",
    },
    separator = "---",
    label = function(t)
      return ("[%s]"):format(t.name:upper())
    end,
    format = nil,
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

--- Resolves an option that is either the value itself or a function returning it.
---@generic T
---@param value T|fun(...): T
---@return T
function M.resolve(value, ...)
  if type(value) == "function" then
    return value(...)
  end

  return value
end

return M
