# annotate.nvim

Leave typed notes on lines, ranges and whole files of a git repository, on ordinary buffers or inside diff views, and export them as one markdown document for an AI agent to work through.

## Features

- One store per repository, kept under `stdpath("data")/annotate`, archived instead of deleted when cleared.
- Typed notes, where every type carries the instruction the agent receives for it.
- Notes follow their lines while you edit; the new positions are written back on save.
- Source based system, where each source decides which buffers it can annotate and how a line maps to a repository location. Ordinary files and [diffview](https://github.com/dlyongemallo/diffview-plus.nvim) buffers are supported out of the box.
- Export to a file, the clipboard, or your own function.

## Requirements

- Neovim 0.11+, 0.13+ for file logging through `vim.log`.
- `git` on the `PATH`.
- [snacks.nvim](https://github.com/folke/snacks.nvim) is recommended for the input window, the picker and the preview. Without it the input falls back to `vim.ui.input` and the picker to `vim.ui.select`.
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
  -- tried in order, the first source that matches a buffer wins
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
    -- "file" | "clipboard" | "both" | fun(markdown, annotations)
    to = "both",
    prompt = "These are my review notes on this repository. Each section below groups one kind of note, and its line under Description says what I expect for that kind. Work through every item: re-read the code at each location before acting, since lines may have moved since I wrote the note, and do what the note's type asks. Questions are for us to settle together, so bring them back to me instead of deciding them yourself. When you finish, report back item by item: what you changed, where you applied a general or praise note, what you decided on each suggestion and why, and the questions still waiting on me.",
    clipboard_message = "Here are my review notes for this repository. Read the attached file and work through every item as it describes.",
  },
})
```

`types` is a list, so setting it replaces the defaults as a whole.

### Input

The input is a floating snacks.nvim window with markdown highlighting. The title shows the current type, the footer shows the keys.

- `cycle` advances through the types in the configured order, in insert and normal mode.
- `submit` saves the note, in insert and normal mode. An empty note is discarded.
- `cancel` closes the window without saving, in normal mode.

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

A file is written to `<tmpdir>/annotate/<repository>-<YYYYmmdd-HHMMSS>.md`. When a file is written, the clipboard (`+` and `*`) receives `export.clipboard_message` followed by a blank line and `@<path>`, otherwise it receives the whole markdown.

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

## Commands

`:Annotate <subcommand>`

| Subcommand | Action |
| --- | --- |
| `add` | Annotate the current line, or the given range with `:'<,'>Annotate add`. |
| `file` | Annotate the current file as a whole. |
| `edit` | Edit the note under the cursor. |
| `delete` | Delete the note under the cursor after confirmation. |
| `next` / `prev` | Jump to the next or previous note in the buffer. |
| `pick` | Pick a note of the repository and jump to it. |
| `quickfix` | Send the notes of the repository to the quickfix list. |
| `export [file\|clipboard\|both]` | Export the notes. |
| `preview` | Preview the export. |
| `clear` | Archive the notes of the repository and clear them. |

## Health

`:checkhealth annotate` reports the Neovim version and whether file logging is available, whether snacks.nvim and git are available, the repository and store for the working directory, and whether diffview is available.
