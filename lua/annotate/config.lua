local M = {}

---@class annotate.TypeText
---@field prompt string
---@field reach? table<string, string> prompt replacing `prompt` for a reach of the type

---@class annotate.Type
---@field key string
---@field name string
---@field icon string
---@field hl string
---@field reaches string[] how far a note of the type reaches, the first one is the default
---@field export annotate.TypeText what the agent reading the export is told about the type
---@field external annotate.TypeText what reviewers on the forge are told about the type in the legend
---@field prefill? "selection" start a new note with the annotated lines in a fenced block

---@class annotate.InputKeys
---@field cycle string
---@field cycle_prev string
---@field reach string
---@field selection string
---@field submit string
---@field cancel string
---@field close string

---@alias annotate.InputFormat string|fun(type: annotate.Type, keys: annotate.InputKeys, types: annotate.Type[], index: integer, reach: string): string

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
---@field per_branch boolean keep a store per branch, a detached HEAD uses the store of the repository

---@class annotate.MarksConfig
---@field sign boolean
---@field line_highlight boolean
---@field virtual_text boolean
---@field virtual_text_format fun(annotation: annotate.Annotation, type: annotate.Type, reach: string): string reach is the one of the note, the default of the type when it has none
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
---@field split string|false
---@field restore string|false
---@field restore_delete string|false
---@field restore_clear string|false

---@class annotate.PickerForce
---@field delete boolean
---@field delete_all boolean
---@field split boolean
---@field restore_clear boolean

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
---@field reach string
---@field compared string

---@alias annotate.Section { type: annotate.Type, reach: string, annotations: annotate.Annotation[] }

---@class annotate.ExportConfig
---@field to annotate.ExportTarget
---@field prompt string|fun(default: string, sections: annotate.Section[]): string
---@field clipboard_message string|fun(default: string, path: string): string
---@field dir string
---@field filename string|fun(repository: string): string
---@field repository string
---@field reach table<string, string>|false what each reach means, listed under its heading when set
---@field headings annotate.ExportHeadings
---@field separator string
---@field label fun(type: annotate.Type, reach?: string): string
---@field heading fun(annotation: annotate.Annotation, type: annotate.Type, location: string): string
---@field format? fun(annotations: annotate.Annotation[], opts: annotate.ExportOptions, config: annotate.Config): string

---@class annotate.ExternalSummaryKeys
---@field proceed string[]
---@field cancel string[]

---@class annotate.ExternalConfig
---@field submit boolean
---@field platform? string
---@field gitlab_cli string
---@field github_cli string
---@field summary boolean
---@field summary_keys annotate.ExternalSummaryKeys
---@field legend boolean
---@field legend_prompt string|fun(default: string, sections: annotate.Section[]): string
---@field body fun(annotation: annotate.Annotation, type: annotate.Type, location: string, legend: boolean, reach: string): string

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
---@field publishers? (string|annotate.Publisher)[]
---@field external? annotate.ExternalConfig

---@type annotate.Config
local defaults = {
  log_level = vim.log.levels.INFO,
  types = {
    {
      key = "apply",
      name = "Apply",
      icon = "",
      hl = "Special",
      reaches = { "here", "pattern" },
      export = {
        prompt = "Make the change the note asks for at this location only. Follow its intent over the literal wording, and leave similar code elsewhere alone.",
        reach = {
          pattern = "The note shows one instance of a change I want everywhere. Find every occurrence of the same thing in the repository, apply the change consistently, and list each place you changed.",
        },
      },
      external = {
        prompt = "Please change this as the comment says.",
        reach = {
          pattern = "Please change this here and wherever the same pattern appears.",
        },
      },
    },
    {
      key = "rewrite",
      name = "Rewrite",
      icon = "",
      hl = "Function",
      reaches = { "here" },
      export = {
        prompt = "Replace the code at this location with what the note shows. The fenced block is the replacement I want; apply it as given, adjusting only what is needed for it to compile and fit the surrounding code, and say what you adjusted.",
      },
      external = {
        prompt = "The suggested replacement for these lines; apply it with the suggestion button or adapt it.",
      },
      prefill = "selection",
    },
    {
      key = "consider",
      name = "Consider",
      icon = "",
      hl = "DiagnosticWarn",
      reaches = { "here", "pattern" },
      export = {
        prompt = "An idea for this spot, not an order. Weigh it against the surrounding code: apply it if it holds up, otherwise say why in a sentence or two. Never skip it silently.",
        reach = {
          pattern = "An idea that may fit in many places. Find where it would apply, judge each place on its own, apply it where it holds up, and list both the places you changed and the ones you left, with a reason.",
        },
      },
      external = {
        prompt = "An idea worth considering, not a requirement; take it or say in the thread why not.",
        reach = {
          pattern = "An idea that may fit in other places too; take it where it helps or say in the thread why not.",
        },
      },
    },
    {
      key = "discuss",
      name = "Discuss",
      icon = "",
      hl = "DiagnosticHint",
      reaches = { "here", "pattern" },
      export = {
        prompt = "A decision for us to settle together. Change no code for it. Give your read, the options with their trade-offs and a recommendation, then wait for my answer.",
        reach = {
          pattern = "A decision about something that recurs. Change no code. Find where it occurs, say how widespread it is and how the occurrences differ, give the options and a recommendation, then wait for my answer before touching any of them.",
        },
      },
      external = {
        prompt = "A question to settle in the thread before this merges.",
        reach = {
          pattern = "A question about something that recurs across the change; let's settle it in the thread before this merges.",
        },
      },
    },
    {
      key = "report",
      name = "Report",
      icon = "",
      hl = "DiagnosticInfo",
      reaches = { "here", "pattern" },
      export = {
        prompt = "Change no code. Find out what the note asks about this location, such as what it does, why it is this way, or what depends on it, and report it.",
        reach = {
          pattern = "Change no code. Find every place in the repository like this one and report them as a list, a line on each, noting how they differ.",
        },
      },
      external = {
        prompt = "Could you explain this in the thread?",
        reach = {
          pattern = "Could you list in the thread where else this happens?",
        },
      },
    },
    {
      key = "keep",
      name = "Keep",
      icon = "",
      hl = "DiagnosticOk",
      reaches = { "here", "pattern" },
      export = {
        prompt = "This is the style I want. Change nothing here, and follow it in any code you write or touch.",
        reach = {
          pattern = "This is the reference style for the repository. Change nothing here; sweep the repository for code that drifts from it, bring that code in line, and list each place you changed.",
        },
      },
      external = {
        prompt = "Done well; please keep it this way.",
        reach = {
          pattern = "Done well; this should be the example for similar code, so please bring other places in line with it.",
        },
      },
    },
    {
      key = "context",
      name = "Context",
      icon = "",
      hl = "Comment",
      reaches = { "here" },
      export = {
        prompt = "Background for the other notes: why the code is this way, a constraint, or history. Nothing to do for it by itself; use it while working through the rest.",
      },
      external = {
        prompt = "Background for the other comments; nothing to change for it by itself.",
      },
    },
  },
  default_type = nil,
  sources = { "diffview", "repo" },
  archive_days = 30,
  confirm_delete = true,
  store = {
    dir = vim.fs.joinpath(vim.fn.stdpath("data"), "annotate"),
    per_branch = false,
  },
  marks = {
    sign = true,
    line_highlight = true,
    virtual_text = true,
    virtual_text_format = function(annotation, t, reach)
      local scope = annotation.line == 0 and "file" or annotation.line_end and ("%d-%d"):format(annotation.line, annotation.line_end)

      return ("%s%s [%s](%s): %s"):format(scope and scope .. "  " or "", t.icon, t.name:upper(), reach, vim.split(annotation.text, "\n", { plain = true })[1])
    end,
    blend = 0.15,
    priority = 4096,
  },
  input = {
    width = 80,
    height = 10,
    border = "rounded",
    position = "float",
    title = function(_, _, types, index)
      local names = {}
      for i, t in ipairs(types) do
        table.insert(names, i == index and ("[%s %s]"):format(t.icon, t.name) or ("%s %s"):format(t.icon, t.name))
      end

      return table.concat(names, " · ")
    end,
    title_pos = "center",
    footer = function(t, keys, _, _, reach)
      local reaches = vim.tbl_map(function(r)
        return r == reach and #t.reaches > 1 and ("[%s]"):format(r) or r
      end, t.reaches)

      return (" %s%s  %s/%s cycle  %s selection  %s submit  %s close "):format(
        table.concat(reaches, " · "),
        #t.reaches > 1 and ("  %s reach"):format(keys.reach) or "",
        keys.cycle_prev,
        keys.cycle,
        keys.selection,
        keys.submit,
        keys.close
      )
    end,
    footer_pos = "center",
    filetype = "annotate",
    markdown = true,
    keys = {
      cycle = "<C-n>",
      cycle_prev = "<C-p>",
      reach = "<C-l>",
      selection = "<C-y>",
      submit = "<C-s>",
      cancel = "q",
      close = "<C-q>",
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
      split = "<C-c>",
      -- in pick({ all = true })
      restore = "<C-r>",
      restore_delete = "<C-d>",
      restore_clear = "<C-x>",
    },
    force = {
      delete = false,
      delete_all = false,
      split = false,
      restore_clear = false,
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
    prompt = "These are my review notes on this repository. Each section below groups one kind of note, and its line under Description says what to do with that kind. Work through every item: re-read the code at each location before acting, since lines may have moved since I wrote the note. Bring back anything that needs me one at a time, with its file, line and a one-line summary of the code there. When you finish, report back item by item.",
    clipboard_message = "Here are my review notes for this repository. Read the attached file and work through every item as it describes.",
    dir = vim.fs.joinpath(vim.uv.os_tmpdir(), "annotate"),
    filename = function(repository)
      return ("%s-%s.md"):format(repository, os.date("%Y%m%d-%H%M%S"))
    end,
    repository = "repository",
    reach = false,
    headings = {
      description = "Description",
      reach = "Reach",
      compared = "Compared",
    },
    separator = "---",
    label = function(t, reach)
      return reach and ("[%s] (%s)"):format(t.name:upper(), reach) or ("[%s]"):format(t.name:upper())
    end,
    heading = function(annotation, _, location)
      return annotation.file and ("### `%s`"):format(location) or ("### %s"):format(location)
    end,
    format = nil,
  },
  publishers = { "gitlab", "github" },
  external = {
    submit = false,
    platform = nil,
    gitlab_cli = "glab",
    github_cli = "gh",
    summary = true,
    summary_keys = {
      proceed = { "<CR>", "y" },
      cancel = { "q", "<Esc>", "n" },
    },
    legend = false,
    legend_prompt = "Each comment in this review is marked with its kind; here is what each kind asks of you.",
    body = function(annotation, t, _, legend, reach)
      return legend and ("**[%s] (%s)**\n\n%s"):format(t.name:upper(), reach, annotation.text) or annotation.text
    end,
  },
}

---@type annotate.Config
---@diagnostic disable-next-line: missing-fields
M.options = vim.deepcopy(defaults)

---@param config? annotate.Config
---@return annotate.Config
function M.setup(config)
  M.options = vim.tbl_deep_extend("force", {}, defaults, config or {})
  for _, t in ipairs(M.options.types) do
    t.reaches = t.reaches or { "here" }
  end

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

--- The prompt of a type for a reach, `export` for the agent or `external` for the forge.
---@param t annotate.Type
---@param kind "export"|"external"
---@param reach string
---@return string
function M.prompt(t, kind, reach)
  return t[kind].reach and t[kind].reach[reach] or t[kind].prompt
end

--- A text option of a config section, called with its default and `...` when it is a function.
---@param section "export"|"external"
---@param key string
---@return string
function M.text(section, key, ...)
  return M.resolve(M.options[section][key], defaults[section][key], ...)
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
