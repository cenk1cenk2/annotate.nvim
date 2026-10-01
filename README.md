# annotate.nvim

Leave typed notes on lines, ranges and whole files of a git repository, on ordinary buffers or inside diff views, and export them as one markdown document for an AI agent to work through.

## Features

- One store per repository, kept under `store.dir` (`stdpath("data")/annotate` by default), archived instead of deleted when cleared, with archives pruned after `archive_days` (30 by default).
- Typed notes, where every type carries the instruction the agent receives for it.
- Notes follow their lines while you edit; the new positions are written back on save.
- Source based system, where each source decides which buffers it can annotate and how a line maps to a repository location. Ordinary files and [diffview](https://github.com/dlyongemallo/diffview-plus.nvim) buffers are supported out of the box.
- Export to a file, the clipboard, or your own function.

## Requirements

- Neovim 0.11+, 0.13+ for file logging through `vim.log`.
- `git` on the `PATH`.
- [snacks.nvim](https://github.com/folke/snacks.nvim) is recommended for the input window, the picker, the hover float and the preview. Without it the input falls back to `vim.ui.input`, the picker to `vim.ui.select` and the hover float to `vim.lsp.util.open_floating_preview`.
- [diffview-plus.nvim](https://github.com/dlyongemallo/diffview-plus.nvim) is optional, for annotating revisions inside diff views.

## Installation

### lazy.nvim

There are no default keymaps, the example below puts them under a leader group.

```lua
return {
  "cenk1cenk2/annotate.nvim",
  dependencies = { "folke/snacks.nvim" },
  cmd = { "Annotate" },
  keys = {
    { "<leader>a", group = "annotate" },
    {
      "<leader>aa",
      function()
        require("annotate").add()
      end,
      mode = { "n", "v" },
      desc = "Annotate line or selection",
    },
    {
      "<leader>af",
      function()
        require("annotate").add_file()
      end,
      desc = "Annotate file",
    },
    {
      "<leader>ae",
      function()
        require("annotate").edit()
      end,
      desc = "Edit annotation",
    },
    {
      "<leader>ad",
      function()
        require("annotate").delete()
      end,
      desc = "Delete annotation",
    },
    {
      "<leader>as",
      function()
        require("annotate").show()
      end,
      desc = "Show annotation",
    },
    {
      "<leader>ap",
      function()
        require("annotate").pick()
      end,
      desc = "Pick annotation",
    },
    {
      "<leader>aq",
      function()
        require("annotate").quickfix()
      end,
      desc = "Annotations to quickfix",
    },
    {
      "<leader>ax",
      function()
        require("annotate").export()
      end,
      desc = "Export annotations",
    },
    {
      "<leader>av",
      function()
        require("annotate").preview()
      end,
      desc = "Preview export",
    },
    {
      "<leader>aC",
      function()
        require("annotate").clear()
      end,
      desc = "Archive and clear annotations",
    },
    {
      "]a",
      function()
        require("annotate").next()
      end,
      desc = "Next annotation",
    },
    {
      "[a",
      function()
        require("annotate").prev()
      end,
      desc = "Previous annotation",
    },
  },
  opts = {},
}
```

## Configuration

The default plugin configuration for the setup function is as below.

```lua
require("annotate").setup({
  log_level = vim.log.levels.INFO,
  -- ordered: the first entry is the default type, the order drives cycling in the input and the section order of the export
  types = {
    {
      key = "issue",
      name = "Issue",
      icon = "",
      hl = "Special",
      prompt = "Something here is wrong or not the way I want it. The note says what to change and how, in general terms, and may say what I dislike about how it is now. Work out the concrete change from that direction: apply it here and anywhere the same problem appears, follow the intent rather than the literal wording, and tell me where you applied it.",
    },
    {
      key = "general",
      name = "General",
      icon = "",
      hl = "DiagnosticInfo",
      prompt = "A note about the repository as a whole, not only the line it is pinned to. Treat the location as one example: find every place the same thing applies, handle it there too, and list where you applied it.",
    },
    {
      key = "suggestion",
      name = "Suggestion",
      icon = "",
      hl = "DiagnosticWarn",
      prompt = "An idea worth weighing, not an order. Evaluate it honestly against the surrounding code: apply it if it holds up, and if you decide against it, say why in a sentence or two. Never skip it silently.",
    },
    {
      key = "question",
      name = "Question",
      icon = "",
      hl = "DiagnosticHint",
      prompt = "A question for us to settle together, not for you to answer alone. Change no code for it. Give your read, the options and their trade-offs, recommend one, and wait for my answer before acting on anything it decides.",
    },
    {
      key = "bug",
      name = "Bug",
      icon = "",
      hl = "DiagnosticError",
      prompt = "This is, or will cause, a bug, and the note says how it shows up. Confirm the failure by reproducing it or reasoning it through from the code, fix the cause rather than the symptom, and add a test that fails without the fix whenever the code is testable.",
    },
    {
      key = "context",
      name = "Context",
      icon = "",
      hl = "Comment",
      prompt = "Background for the other notes: why the code is this way, a constraint, or history. Do not act on it by itself; use it while you work through the rest.",
    },
    {
      key = "praise",
      name = "Praise",
      icon = "",
      hl = "DiagnosticOk",
      prompt = "This is the pattern I want. Keep it, and treat it as the reference: look for places that drift from it, bring them in line, and list each one you changed.",
    },
  },
  -- key of the type a new note starts on, nil for the first entry of types
  default_type = nil,
  -- tried in order, the first source that matches a buffer wins
  sources = { "diffview", "repo" },
  archive_days = 30,
  -- ask before deleting a note, `force` skips it per call
  confirm_delete = true,
  store = {
    -- directory holding one store file per repository and the archive
    dir = vim.fs.joinpath(vim.fn.stdpath("data"), "annotate"),
  },
  marks = {
    -- type icon in the sign column
    sign = true,
    -- tinted background on annotated lines
    line_highlight = true,
    -- summary at the end of the line, or above the first line for whole-file notes
    virtual_text = true,
    -- text of the summary
    virtual_text_format = function(annotation, t)
      return ("%s %s: %s"):format(t.icon, t.name, vim.split(annotation.text, "\n", { plain = true })[1])
    end,
    -- share of the type color mixed into the Normal background for the line highlight
    blend = 0.15,
    -- extmark priority of signs, line highlights and virtual text
    priority = 4096,
  },
  input = {
    width = 80,
    height = 10,
    border = "rounded",
    -- snacks.nvim window position
    position = "float",
    -- string or fun(type, keys, types, index), re-evaluated when cycling types
    title = function(_, _, types, index)
      local names = {}
      for i, t in ipairs(types) do
        table.insert(names, i == index and ("[%s %s]"):format(t.icon, t.name) or ("%s %s"):format(t.icon, t.name))
      end

      return (" %s "):format(table.concat(names, " · "))
    end,
    title_pos = "center",
    -- string or fun(type, keys, types, index), evaluated when the window opens
    footer = function(_, keys)
      return (" %s/%s cycle  %s submit  %s cancel "):format(keys.cycle_prev, keys.cycle, keys.submit, keys.cancel)
    end,
    footer_pos = "center",
    -- filetype of the input buffer
    filetype = "annotate",
    -- markdown treesitter highlighting in the input buffer
    markdown = true,
    keys = {
      cycle = "<C-n>",
      cycle_prev = "<C-p>",
      submit = "<C-s>",
      cancel = "q",
    },
  },
  show = {
    -- nil inherits input.border
    border = nil,
    max_width = 80,
    max_height = 20,
    -- a second show() enters the float
    focusable = true,
  },
  picker = {
    -- "snacks" | "select", nil uses snacks.nvim when available
    backend = nil,
    title = "Annotations",
    -- actions on the selected notes in the snacks.nvim picker, false disables one
    keys = {
      edit = "<C-e>",
      delete = "<C-d>",
      delete_all = "<C-x>",
      type = "<C-t>",
    },
    -- skip the confirmation of the delete and delete_all actions
    force = {
      delete = false,
      delete_all = false,
    },
  },
  quickfix = {
    title = "annotate",
    -- open the quickfix window after filling it
    open = true,
  },
  notify = {
    -- title of the notifications
    title = "annotate",
  },
  export = {
    -- "file" | "clipboard" | "both" | fun(markdown, annotations)
    to = "both",
    prompt = "These are my review notes on this repository. Each section below groups one kind of note, and its line under Description says what I expect for that kind. Work through every item: re-read the code at each location before acting, since lines may have moved since I wrote the note, and do what the note's type asks. Questions are for us to settle together, so bring them back to me instead of deciding them yourself. When you finish, report back item by item: what you changed, where you applied an issue, general or praise note, what you decided on each suggestion and why, and the questions still waiting on me.",
    clipboard_message = "Here are my review notes for this repository. Read the attached file and work through every item as it describes.",
    -- directory exported files are written to
    dir = vim.fs.joinpath(vim.uv.os_tmpdir(), "annotate"),
    -- string or fun(repository), name of the exported file
    filename = function(repository)
      return ("%s-%s.md"):format(repository, os.date("%Y%m%d-%H%M%S"))
    end,
    -- section headings of the document
    headings = {
      description = "Description",
      compared = "Compared",
    },
    -- line between the type sections
    separator = "---",
    -- how a type is named in the document
    label = function(t)
      return ("[%s]"):format(t.name:upper())
    end,
    -- fun(annotations, opts, config): markdown, replaces the built-in document when set
    format = nil,
  },
})
```

`types` is a list, so setting it replaces the defaults as a whole.

### Input

The input is a floating snacks.nvim window with markdown highlighting. The title lists every type with the current one in brackets, the footer shows the keys.

- `cycle` advances through the types in the configured order, in insert and normal mode.
- `cycle_prev` goes back through the types, in insert and normal mode.
- `submit` saves the note, in insert and normal mode. An empty note is discarded.
- `cancel` closes the window without saving, in normal mode.

### Picker

`<CR>` jumps to the note. The snacks.nvim picker binds the `picker.keys` actions in insert and normal mode, and lists them in its help. The `select` backend has no actions.

- `edit` opens the input on the note and updates it in place.
- `delete` deletes the selected notes, or the one under the cursor, asking first when `confirm_delete` is set unless `picker.force.delete` is.
- `delete_all` archives and clears every note after confirmation, skipped with `picker.force.delete_all`, like `clear`, and closes the picker.
- `type` moves the selected notes to the next type in the configured order.

### Show

`require("annotate").show()` opens a float at the cursor, like a hover, with every note covering the cursor line: its type, location, the type's prompt and the full text, separated by a rule. It closes when the cursor moves or the buffer is left, or with `q` and `<Esc>`. Calling it again while it is open enters the float.

### Overlapping Notes

`show`, `edit` and `delete` act on every note covering the cursor line, ranges included. On line 1 a whole-file note counts when nothing else covers it. When several notes overlap, `edit` and `delete` ask which one through `vim.ui.select`, and `delete` also offers all of them.

`delete({ force = true })` and `clear({ force = true })` skip the confirmation, never the choice between overlapping notes.

## Sources

A source decides whether it can annotate a buffer and maps a line range of that buffer to a location in the repository.

- `repo` handles ordinary file buffers inside the git repository of the working directory. Paths are stored relative to the repository root with symlinks resolved.
- `diffview` handles the `diffview://` buffers of a diff view, which show a commit, a stage of the index, or a custom revision. Notes on them store that revision. The working tree side of a diff view is an ordinary file and is handled by `repo`.

While a diff view is open in the current tabpage, notes from either side also record the two revisions being compared.

Locations look as follows.

```lua
---@class annotate.Location
---@field file string path relative to the repository root
---@field line integer 1-based, 0 for a whole-file annotation
---@field line_end? integer
---@field rev? string nil for the working tree, otherwise a commit or a stage like `:0:`
---@field context? { left: string, right: string }
```

### Adding a Source

A source is a table with a `name`, a `match` and a `resolve` function. Register it, then reference it in `sources`, or put the table into `sources` directly.

```lua
local annotate = require("annotate")

annotate.sources.register({
  name = "scratch",
  match = function(bufnr)
    return vim.b[bufnr].scratch_file ~= nil
  end,
  resolve = function(bufnr, line1, line2)
    return {
      file = vim.b[bufnr].scratch_file,
      line = line1,
      line_end = line2 > line1 and line2 or nil,
    }
  end,
})

annotate.setup({
  sources = { "scratch", "diffview", "repo" },
})
```

## Export

`require("annotate").export(opts)` renders every note of the repository and delivers the markdown, returning it as well.

- `to`: `"file"`, `"clipboard"`, `"both"` or a `fun(markdown, annotations)`, defaults to `export.to`.
- `prompt`: overrides `export.prompt` for this export.
- `types`: a subset of type keys to export.
- `clear`: archives the notes after exporting.

A file is written to `export.dir`, named by `export.filename`, which defaults to `<tmpdir>/annotate/<repository>-<YYYYmmdd-HHMMSS>.md`. When a file is written, the clipboard (`+` and `*`) receives `export.clipboard_message` followed by a blank line and `@<path>`, otherwise it receives the whole markdown.

`require("annotate").preview(opts)` shows the same markdown in a floating window without delivering it.

The document has the following shape. Only types with at least one note appear, in the configured order. `Compared` only appears when a note was taken inside a diff view. Notes are sorted by file and line. Notes on a revision are marked with `~` and `@ <rev>`, whole-file notes only show the path.

```markdown
<export.prompt>

## Description

- [GENERAL]: <prompt of the general type>
- [BUG]: <prompt of the bug type>

## Compared

- `a1b2c3d4e5f` .. `LOCAL`

## [GENERAL]

- `lua/a.lua` - applies to the whole file

---

## [BUG]

- `lua/a.lua:12` - single line
- `lua/a.lua:12-18` - a range
  with a second line of text
- `lua/b.lua:~7 @ a1b2c3d4e5f` - on a commit
```

### Custom Export Format

`export.format` replaces the built-in document as a whole. It receives the annotations, the export options and the configuration, and returns the markdown that gets delivered and previewed.

```lua
require("annotate").setup({
  export = {
    format = function(annotations, opts, config)
      local lines = { opts.prompt or config.export.prompt, "" }
      for _, annotation in ipairs(annotations) do
        if not opts.types or vim.list_contains(opts.types, annotation.type) then
          table.insert(lines, ("- %s `%s:%d` %s"):format(annotation.type, annotation.file, annotation.line, annotation.text))
        end
      end

      return table.concat(lines, "\n") .. "\n"
    end,
  },
})
```

## Commands

`:Annotate <subcommand>`

| Subcommand | Action |
| --- | --- |
| `add` | Annotate the current line, or the given range with `:'<,'>Annotate add`. |
| `file` | Annotate the current file as a whole. |
| `edit` | Edit the note under the cursor. |
| `show` | Show the notes under the cursor in a float. |
| `delete` | Delete the note under the cursor after confirmation, `delete!` without it. |
| `next` / `prev` | Jump to the next or previous note in the buffer. |
| `pick` | Pick a note of the repository and jump to it. |
| `quickfix` | Send the notes of the repository to the quickfix list. |
| `export [file\|clipboard\|both]` | Export the notes. |
| `preview` | Preview the export. |
| `clear` | Archive the notes of the repository and clear them after confirmation, `clear!` without it. |

## Health

`:checkhealth annotate` reports the Neovim version and whether file logging is available, whether snacks.nvim and git are available, the repository and store for the working directory, and whether diffview is available.
