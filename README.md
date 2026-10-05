# annotate.nvim

Leave typed notes on lines, ranges and whole files of a project, on ordinary buffers or inside diff views, and export them as one markdown document for an AI agent to work through.

## Features

- One store per repository, kept under `store.dir` (`stdpath("data")/annotate` by default), archived instead of deleted when cleared and restorable from the archive, with archives pruned after `archive_days` (30 by default).
- Typed notes, where every type carries the instruction the agent receives for it.
- Notes follow their lines while you edit; the new positions are written back on save.
- Source based system, where each source decides which buffers it can annotate and how a line maps to a repository location. Ordinary files and [diffview](https://github.com/dlyongemallo/diffview-plus.nvim) buffers are supported out of the box.
- Export to a file, the clipboard, or your own function.
- Publish the notes to the merge request or pull request of the current branch as review comments, on GitLab and GitHub.

## Requirements

- Neovim 0.11+, 0.13+ for file logging through `vim.log`.
- `git` on the `PATH`.
- [snacks.nvim](https://github.com/folke/snacks.nvim) is recommended for the input window, the picker, the hover float and the preview. Without it the input falls back to `vim.ui.input`, the picker to `vim.ui.select` and the hover float to `vim.lsp.util.open_floating_preview`.
- [diffview-plus.nvim](https://github.com/dlyongemallo/diffview-plus.nvim) is optional, for annotating revisions inside diff views.
- [glab](https://gitlab.com/gitlab-org/cli) or [gh](https://cli.github.com), authenticated for the host of the remote, are optional, for publishing.

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
      "<leader>at",
      function()
        require("annotate").add_with_type()
      end,
      mode = { "n", "v" },
      desc = "Annotate line or selection with a chosen type",
    },
    {
      "<leader>af",
      function()
        require("annotate").add_file()
      end,
      desc = "Annotate file",
    },
    {
      "<leader>aF",
      function()
        require("annotate").add_file_with_type()
      end,
      desc = "Annotate file with a chosen type",
    },
    {
      "<leader>ag",
      function()
        require("annotate").add_repository()
      end,
      desc = "Annotate the repository",
    },
    {
      "<leader>aG",
      function()
        require("annotate").add_repository_with_type()
      end,
      desc = "Annotate the repository with a chosen type",
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
    -- text of the summary, led by `file` for whole-file notes and the line range for multi-line ones
    virtual_text_format = function(annotation, t)
      local scope = annotation.line == 0 and "file" or annotation.line_end and ("%d-%d"):format(annotation.line, annotation.line_end)

      return ("%s%s %s%s: %s"):format(
        scope and scope .. "  " or "",
        t.icon,
        t.name,
        annotation.reach and (" (%s)"):format(annotation.reach) or "",
        vim.split(annotation.text, "\n", { plain = true })[1]
      )
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
    -- string or fun(type, keys, types, index, reach), re-evaluated when cycling types, truncated on both sides around the current type when it does not fit
    title = function(_, _, types, index)
      local names = {}
      for i, t in ipairs(types) do
        table.insert(names, i == index and ("[%s %s]"):format(t.icon, t.name) or ("%s %s"):format(t.icon, t.name))
      end

      return table.concat(names, " · ")
    end,
    title_pos = "center",
    -- string or fun(type, keys, types, index, reach), re-evaluated when cycling types or reaches
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
    -- filetype of the input buffer; registered as a treesitter alias of markdown.
    -- The buffer also carries `vim.b.annotate = true` and `vim.b.annotate_origin` (the annotated buffer)
    filetype = "annotate",
    -- markdown treesitter highlighting in the input buffer
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
      split = "<C-c>",
      -- in the restore picker
      restore_delete = "<C-d>",
      restore_clear = "<C-x>",
    },
    -- skip the confirmation of the delete, delete_all and split actions, delete also covers restore_delete
    force = {
      delete = false,
      delete_all = false,
      split = false,
      restore_clear = false,
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
    prompt = "These are my review notes on this repository. Each section below groups one kind of note, and its line under Description says what to do with that kind. Work through every item: re-read the code at each location before acting, since lines may have moved since I wrote the note. Bring back anything that needs me one at a time, with its file, line and a one-line summary of the code there. When you finish, report back item by item.",
    clipboard_message = "Here are my review notes for this repository. Read the attached file and work through every item as it describes.",
    -- directory exported files are written to
    dir = vim.fs.joinpath(vim.uv.os_tmpdir(), "annotate"),
    -- string or fun(repository), name of the exported file
    filename = function(repository)
      return ("%s-%s.md"):format(repository, os.date("%Y%m%d-%H%M%S"))
    end,
    -- location shown for notes attached to no file (`add_repository`); export lists them as plain items
    repository = "repository",
    -- table of reach to what it means, listed under its heading for the reaches in use; false leaves it to the type prompts
    reach = false,
    -- section headings of the document
    headings = {
      description = "Description",
      reach = "Reach",
      compared = "Compared",
    },
    -- line between the sections
    separator = "---",
    -- fun(type, reach): string, how a type and reach are named in the document
    label = function(t, reach)
      return reach and ("[%s] (%s)"):format(t.name:upper(), reach) or ("[%s]"):format(t.name:upper())
    end,
    -- fun(annotation, type, location): string, the heading above each note
    heading = function(annotation, _, location)
      return annotation.file and ("### `%s`"):format(location) or ("### %s"):format(location)
    end,
    -- fun(annotations, opts, config): markdown, replaces the built-in document when set
    format = nil,
  },
  -- tried in order against the url of the remote, the first one that matches publishes
  publishers = { "gitlab", "github" },
  -- publishing to the forge, see Publishing
  external = {
    -- submit the review instead of only staging it
    submit = false,
    -- name of the publisher to use regardless of the remote url, for self-hosted forges
    platform = nil,
    gitlab_cli = "glab",
    github_cli = "gh",
    -- show what goes where and ask before posting
    summary = true,
    summary_keys = {
      proceed = { "<CR>", "y" },
      cancel = { "q", "<Esc>", "n" },
    },
    -- label each comment with its type and post a legend of the types once per merge or pull request
    legend = false,
    -- first line of the legend, followed by each used type and reach with its external prompt
    legend_prompt = "Each comment in this review is marked with its kind; here is what each kind asks of you.",
    -- fun(annotation, type, location, legend, reach): string, the comment posted for a note
    body = function(annotation, t, _, legend, reach)
      return legend and ("**[%s] (%s)**\n\n%s"):format(t.name:upper(), reach, annotation.text) or annotation.text
    end,
  },
})
```

`types` is a list, so setting it replaces the defaults as a whole.

A type is what the agent should do with a note: `apply` it, `rewrite` the lines with the fenced block, `consider` it, `discuss` it before acting, `report` on it without changing code, `keep` the style it points at, or take it as `context`.

`reaches` says how far a note of the type reaches, the first entry being the default:

- `here` is the location of the note only: its lines, its file for a whole-file note, the repository for a repository note.
- `pattern` takes the location as one example of something to handle wherever it occurs, like a sweep over the repository for `keep`.

A note stores its reach only when it is not the default of its type. Notes of the types of earlier versions are mapped when the store is read, unless a configured type still has their key: `issue` and `bug` to `apply`, `general` to `apply` with `pattern`, `suggestion` to `consider`, `question` to `discuss` and `praise` to `keep`.

Each type describes itself twice, for two different readers:

- `export.prompt` is written for the agent working through the export: what to do with notes of this kind. It fills the Description section of the export and shows in `show()` and the type chooser.
- `external.prompt` is written for the people on the merge or pull request: the author and other reviewers. It is only used in the legend posted when publishing with `external.legend`.

`export.reach` and `external.reach` replace the prompt for a reach of the type, so a `pattern` note can ask for a sweep where a `here` note asks for a local change. `:checkhealth annotate` warns about a prompt for a reach the type does not have.

### Input

The input is a floating snacks.nvim window with markdown highlighting. The title lists every type with the current one in brackets, the footer shows the reaches of the current type, the current one in brackets, and the keys.

- `cycle` advances through the types in the configured order, in insert and normal mode.
- `cycle_prev` goes back through the types, in insert and normal mode. Cycling onto a type that does not have the current reach falls back to its default.
- `reach` cycles through the reaches of the current type, in insert and normal mode.
- `selection` inserts the annotated lines in a fenced block tagged with the filetype below the cursor, or as the whole note when it is empty, in insert and normal mode.
- `submit` saves the note, in insert and normal mode. An empty note is discarded.
- `cancel` closes the window without saving, in normal mode.

A type with `prefill = "selection"`, like `rewrite`, starts a new note with the annotated lines in a fenced block tagged with the filetype of the annotated buffer, the cursor on its first line, so the note is the replacement you want. Cycling to such a type while the input is still empty fills it the same way, and cycling away from an untouched prefill empties the input again; text you wrote is never touched. The buffer and lines are taken when the command runs, so `add_with_type` prefills from where you were before the type chooser opened. Editing a note keeps its text, and whole-file and repository notes are never prefilled.

### Picker

Each row shows the type icon and name, the reach when it is not the default of the type, the location (`path:line`, `path:line-end`, `path` for a whole file, `repository`, with `~` and `@ <rev>` for a revision), the first line of the note, and where it was posted, like `draft !5, published #1`.

`<CR>` jumps to the note. The snacks.nvim picker binds the `picker.keys` actions in insert and normal mode, and lists them in its help. The `select` backend has no actions.

- `edit` opens the input on the note and updates it in place.
- `delete` deletes the selected notes, or the one under the cursor, asking first when `confirm_delete` is set unless `picker.force.delete` is.
- `delete_all` archives and clears every note after confirmation, skipped with `picker.force.delete_all`, like `clear`, and closes the picker.
- `type` moves the selected notes to the next type in the configured order, dropping a reach the next type does not have.
- `split` archives every note as a snapshot, then keeps only the selected notes, or the one under the cursor, in the store with their ids and where they were posted, so they start a new session. It confirms unless `picker.force.split` is set, and closes the picker.

`<Tab>` and `<S-Tab>` select notes, as snacks.nvim binds them by default.

### Show

`require("annotate").show()` opens a float at the cursor, like a hover, with every note covering the cursor line: its type, location, the type's prompt and the full text, separated by a rule. It closes when the cursor moves or the buffer is left, or with `q` and `<Esc>`. Calling it again while it is open enters the float.

### Overlapping Notes

`show`, `edit` and `delete` act on every note covering the cursor line, ranges included. On line 1 a whole-file note counts when nothing else covers it. When several notes overlap, `edit` and `delete` ask which one through `vim.ui.select`, and `delete` also offers all of them.

`delete({ force = true })` and `clear({ force = true })` skip the confirmation, never the choice between overlapping notes.

## Archive

`clear` never deletes notes: it moves the store of the repository into the archive under `store.dir`, named by the time it was archived. Archives older than `archive_days` are pruned.

`require("annotate").restore(opts)` lists the archives of the repository, newest first, with their time, note count and notes per type, previewing each one as the export markdown. Choosing one restores it and removes it from the archive.

- An empty store takes the archive as it is.
- Otherwise the current notes are archived first, so nothing is lost, and the archive replaces them. `opts.mode = "merge"` appends the notes of the archive the store does not have yet instead.

In the snacks.nvim picker, `restore_delete` permanently deletes the selected archives and keeps the picker open, `restore_clear` permanently deletes every archive of the repository and closes it. Both confirm unless `picker.force.delete` or `picker.force.restore_clear` is set. `require("annotate").clear_archive({ force = true })` does the same as `restore_clear` outside the picker.

## Sources

A source decides whether it can annotate a buffer and maps a line range of that buffer to a location in the repository.

- `repo` handles ordinary file buffers inside the git repository of the working directory, or inside the working directory itself when it is not in a repository. Paths are stored relative to that root with symlinks resolved. Publishing still needs a git repository.
- `diffview` handles the `diffview://` buffers of a diff view, which show a commit, a stage of the index, or a custom revision. Notes on them store that revision. The working tree side of a diff view is an ordinary file and is handled by `repo`.

While a diff view is open in the current tabpage, notes from either side also record the two revisions being compared.

Locations look as follows.

```lua
---@class annotate.Location
---@field file string path relative to the repository root, or the working directory outside a repository
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

The document has the following shape. A section holds the notes of one type and reach, and only sections with at least one note appear, in the configured order of the types and their reaches. Each Description line carries the prompt of that type for that reach. `Compared` only appears when a note was taken inside a diff view. Each note is a `###` heading carrying its location, followed by its text as free-flowing markdown. Repository notes come first in their section, then file notes sorted by file and line. Notes on a revision are marked with `~` and `@ <rev>`, whole-file notes only show the path.

```markdown
<export.prompt>

## Description

- [APPLY] (here): <prompt of the apply type>
- [APPLY] (pattern): <pattern prompt of the apply type>
- [DISCUSS] (here): <prompt of the discuss type>

## Compared

- `a1b2c3d4e5f` .. `LOCAL`

## [APPLY] (here)

### repository

Applies to the repository as a whole.

### `lua/a.lua`

Applies to the whole file.

---

## [APPLY] (pattern)

### `lua/a.lua:4`

One instance of something to change everywhere.

---

## [DISCUSS] (here)

### `lua/a.lua:12-18`

A range, with the note written as markdown:

- a list
- `inline code`

### `lua/b.lua:~7 @ a1b2c3d4e5f`

On a commit.
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

## Publishing

`require("annotate").publish(opts)` posts the notes of the repository to the open merge request (GitLab) or pull request (GitHub) of the current branch as review comments, the way a human review lands. Only the note text goes out, never the type prompts.

It talks to the forge through `glab api` and `gh api` (`external.gitlab_cli`, `external.github_cli`), which must be authenticated for the host of the remote. Every call runs in the background; progress, the outcome and the CLI's stderr on failure arrive as notifications.

- The remote is `opts.remote`, otherwise the upstream remote of the current branch. Without an upstream the only remote is used, and with several the choice is asked once per repository and session.
- The publisher is the first of `publishers` whose `match` accepts the remote url: `github.com` goes to GitHub, a host containing `gitlab` to GitLab. `external.platform` names the publisher for other hosts.
- The merge or pull request is the open one whose source branch is the upstream branch.
- Publishing refuses when the local `HEAD` is not the head of the merge or pull request, since lines may not match its diff.

### What Goes Where

A note is inside the diff when every line of it falls into one hunk of the file's diff: the new side for working tree notes and notes on the head commit, the old side for notes taken on the merge base (`~` in the export).

| Note | GitLab | GitHub |
| --- | --- | --- |
| Lines inside the diff | Draft note positioned on the lines (`new_line` or `old_line`, plus `line_range` with GitLab line codes for a range) | Review comment on the lines (`line`, `start_line`, `side` `RIGHT` or `LEFT`) |
| Lines outside the diff | General draft note, prefixed with `` `path:line` `` | File comment, prefixed with `` `path:line` ``, or a conversation comment when the file is not in the diff |
| Whole file | General draft note naming the file | File comment, or a conversation comment when the file is not in the diff |
| Repository | General draft note | Conversation comment |

Every note is its own comment, nothing is merged together. GitHub conversation comments (`POST /repos/{owner}/{repo}/issues/{number}/comments`) can not be drafts, so staging only queues them in the store, shown as `queued, posted on submit` in the summary, and the submit posts them one by one after the review. The review body only carries the review note of the submit.

Each comment is the note's markdown as it is, without its type, since reviewers on the forge do not know what the types mean. With `external.legend = true`, or `publish({ legend = true })` for one call, each comment starts with `**[<TYPE>] (<reach>)**` and a blank line, and a legend is posted once per merge or pull request: `external.legend_prompt` followed by every type and reach in use with its external prompt. It is its own note: a general draft note on GitLab, a queued conversation comment on GitHub; it is recorded in the store like a note, so it is not posted twice. `external.body` changes the comment.

A note of a `prefill = "selection"` type, like `rewrite`, positioned on the new side of the diff turns its first fenced block into the forge's suggestion, which the author applies with one click: ` ```suggestion ` spanning the annotated lines on GitHub, ` ```suggestion:-0+N ` from the first annotated line on GitLab. Text around the block stays as it is. Suggestions only work in the diff, so a rewrite outside it keeps its plain block and the summary counts it.

### Staging and Submitting

Before anything is posted, a float shows the plan in the shape of the export: the target with its branches, URL and head, the totals, whether the legend is on and its text, then every note with its destination, whether it is new, an update or skipped, and the exact body that is sent. `<CR>` or `y` proceeds, `q`, `<Esc>` or `n` cancels (`external.summary_keys`). `opts.force` or `external.summary = false` skips it.

- Staging, the default, leaves everything as drafts only you can see: GitLab draft notes, or a pending GitHub review. Nothing reaches the author.
- Submitting (`opts.publish = true`, `external.submit`, or `:Annotate publish!`) asks, after the summary and before anything is posted, for the verdict and then for an optional review note (submitting it empty means none, closing it cancels the submit), then publishes every draft at once, including the ones staged earlier. The chooser only lists the verdicts the forge allows you on that merge or pull request, and when Comment is the only one left it is used without asking, with the reason in the summary's Review section.
  - GitLab reads the merge request's approvals: Approve while you can approve and have not, Unapprove once you have. The drafts are published together, the note is posted as a comment, and Approve approves the merge request at its head.
  - GitHub offers Comment, Approve and Request changes, or only Comment on a pull request you authored, since GitHub refuses the others there. The pending review receives the new comments and is submitted with the verdict and the note as its body.
  - Only open merge and pull requests are considered. A draft is marked in the summary; comments on it are allowed.
  - `opts.verdict` and `opts.note` answer up front, a verdict the target does not allow is refused, and cancelling the verdict cancels the submit.

### Duplicates and Updates

Every posted note records where it went under `posted`: platform, project, merge or pull request, branches, title, URLs, whether it is a draft, queued or published, the body that was sent with its SHA-1, and every id the forge returned for it. On GitLab that is the draft note id, then the note and discussion ids once published, along with the merge request's global id, iid and project id. On GitHub it is the review id and node id, the comment id and node id, the thread node id, the conversation comment id and node id, and the pull request node id.

Publishing to the same merge or pull request again compares each note with what was sent:

- An unchanged note is skipped.
- A changed note is updated in place: `PUT .../draft_notes/:id` or `PUT .../notes/:id` on GitLab, `PATCH .../pulls/comments/:id` for a review comment or `PATCH .../issues/comments/:id` for a conversation comment on GitHub, while a queued note only changes in the store. The summary marks it `update` with the first changed line.
- A note whose draft or comment was deleted on the forge is posted again.

A submit marks the staged drafts as published without posting them again. A note can still go to another merge or pull request. `show()` lists where a note was posted, the picker marks it.

`opts.types` publishes a subset of types, `opts.clear` archives the notes once everything was posted.

## Completion

The input buffer uses the `annotate` filetype, registered as a treesitter alias of markdown, and remembers the buffer it was opened from in `vim.b.annotate_origin`.

For [blink.cmp](https://github.com/Saghen/blink.cmp), `annotate.blink` completes symbol names from that buffer's language servers (`workspace/symbol`) and inserts them as inline code:

```lua
sources = {
  per_filetype = {
    annotate = { inherit_defaults = true, "annotate" },
  },
  providers = {
    annotate = { name = "annotate", module = "annotate.blink" },
  },
},
```

## Commands

`:Annotate <subcommand>`

| Subcommand | Action |
| --- | --- |
| `add` | Annotate the current line, or the given range with `:'<,'>Annotate add`. |
| `add-type` | Like `add`, choosing the type from a list first, showing each type's prompt. |
| `file` | Annotate the current file as a whole. |
| `file-type` | Like `file`, choosing the type from a list first. |
| `repository` | Add a note about the repository as a whole, attached to no file, like a general comment on a pull request. |
| `repository-type` | Like `repository`, choosing the type from a list first. |
| `edit` | Edit the note under the cursor. |
| `show` | Show the notes under the cursor in a float. |
| `delete` | Delete the note under the cursor after confirmation, `delete!` without it. |
| `next` / `prev` | Jump to the next or previous note in the buffer. |
| `pick` | Pick a note of the repository and jump to it. |
| `quickfix` | Send every note of the repository to the quickfix list as `[TYPE] <location>  <first line>  (<posted>)`, with ` (<reach>)` after the type when it is not the default. Repository notes are listed without a file and are not jumped to. Each entry's `type` is the first letter of its type name and its `user_data` holds `id`, `type`, `reach` and `posted`, for quickfix plugins to filter on. |
| `export [file\|clipboard\|both]` | Export the notes. |
| `preview` | Preview the export. |
| `publish` | Stage the notes as drafts on the merge or pull request of the current branch, `publish!` submits the review. |
| `clear` | Archive the notes of the repository and clear them after confirmation, `clear!` without it. |
| `restore` | Pick an archive of the repository and restore it. |
| `clear-archive` | Permanently delete every archive of the repository after confirmation, `clear-archive!` without it. |

## Health

`:checkhealth annotate` reports the Neovim version and whether file logging is available, whether snacks.nvim and git are available, the repository and store for the working directory, whether `glab` and `gh` are available for publishing, and whether diffview is available.
