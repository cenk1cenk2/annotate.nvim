# annotate.nvim

Leave typed notes on lines, ranges and whole files of a git repository, on ordinary buffers or inside diff views, and export them as one markdown document for an AI agent to work through.

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
      "<leader>ag",
      function()
        require("annotate").add_repository()
      end,
      desc = "Annotate the repository",
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
      export = {
        prompt = "Something here is wrong or not the way I want it. The note says what to change and how, in general terms, and may say what I dislike about how it is now. Work out the concrete change from that direction: apply it here and anywhere the same problem appears, follow the intent rather than the literal wording, and tell me where you applied it.",
      },
      external = {
        prompt = "Something here should change. The comment says what and roughly how; please apply it here and wherever the same pattern appears.",
      },
    },
    {
      key = "rewrite",
      name = "Rewrite",
      icon = "",
      hl = "Function",
      export = {
        prompt = "Replace the code at this location with what the note shows. The fenced block is the replacement I want; apply it as given, adjusting only what is needed for it to compile and fit the surrounding code, and say what you adjusted.",
      },
      external = {
        prompt = "The suggested replacement for these lines; apply it with the suggestion button or adapt it.",
      },
      -- a new note starts with the annotated lines in a fenced block tagged with the filetype
      prefill = "selection",
    },
    {
      key = "general",
      name = "General",
      icon = "",
      hl = "DiagnosticInfo",
      export = {
        prompt = "A note about the repository as a whole, not only the line it is pinned to. Treat the location as one example: find every place the same thing applies, handle it there too, and list where you applied it.",
      },
      external = {
        prompt = "A remark about the change as a whole rather than this line alone; it likely applies in other places too.",
      },
    },
    {
      key = "suggestion",
      name = "Suggestion",
      icon = "",
      hl = "DiagnosticWarn",
      export = {
        prompt = "An idea worth weighing, not an order. Evaluate it honestly against the surrounding code: apply it if it holds up, and if you decide against it, say why in a sentence or two. Never skip it silently.",
      },
      external = {
        prompt = "An idea worth considering, not a requirement; take it or say in the thread why not.",
      },
    },
    {
      key = "question",
      name = "Question",
      icon = "",
      hl = "DiagnosticHint",
      export = {
        prompt = "A question for us to settle together, not for you to answer alone. Change no code for it. Give your read, the options and their trade-offs, recommend one, and wait for my answer before acting on anything it decides.",
      },
      external = {
        prompt = "A question for the author; please answer in the thread before this merges.",
      },
    },
    {
      key = "bug",
      name = "Bug",
      icon = "",
      hl = "DiagnosticError",
      export = {
        prompt = "This is, or will cause, a bug, and the note says how it shows up. Confirm the failure by reproducing it or reasoning it through from the code, fix the cause rather than the symptom, and add a test that fails without the fix whenever the code is testable.",
      },
      external = {
        prompt = "This is, or will cause, a bug, and the comment says how it shows up. Please fix the cause and cover it with a test where you can.",
      },
    },
    {
      key = "context",
      name = "Context",
      icon = "",
      hl = "Comment",
      export = {
        prompt = "Background for the other notes: why the code is this way, a constraint, or history. Do not act on it by itself; use it while you work through the rest.",
      },
      external = {
        prompt = "Background for the other comments; nothing to change for it by itself.",
      },
    },
    {
      key = "praise",
      name = "Praise",
      icon = "",
      hl = "DiagnosticOk",
      export = {
        prompt = "This is the pattern I want. Keep it, and treat it as the reference: look for places that drift from it, bring them in line, and list each one you changed.",
      },
      external = {
        prompt = "Something done well; keep it and use it as the example for similar code.",
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
    -- string or fun(type, keys, types, index), re-evaluated when cycling types, truncated on both sides around the current type when it does not fit
    title = function(_, _, types, index)
      local names = {}
      for i, t in ipairs(types) do
        table.insert(names, i == index and ("[%s %s]"):format(t.icon, t.name) or ("%s %s"):format(t.icon, t.name))
      end

      return table.concat(names, " · ")
    end,
    title_pos = "center",
    -- string or fun(type, keys, types, index), evaluated when the window opens
    footer = function(_, keys)
      return (" %s/%s cycle  %s submit  %s cancel "):format(keys.cycle_prev, keys.cycle, keys.submit, keys.cancel)
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
    -- first line of the legend, followed by each used type with its `external.prompt`
    legend_prompt = "Each comment in this review is marked with its kind; here is what each kind asks of you.",
    -- fun(annotation, type, location, legend): string, the comment posted for a note
    body = function(annotation, t, _, legend)
      return legend and ("**[%s]**\n\n%s"):format(t.name:upper(), annotation.text) or annotation.text
    end,
  },
})
```

`types` is a list, so setting it replaces the defaults as a whole.

Each type describes itself twice, for two different readers:

- `export.prompt` is written for the agent working through the export: what to do with notes of this kind. It fills the Description section of the export and shows in `show()` and the type chooser.
- `external.prompt` is written for the people on the merge or pull request: the author and other reviewers. It is only used in the legend posted when publishing with `external.legend`.

### Input

The input is a floating snacks.nvim window with markdown highlighting. The title lists every type with the current one in brackets, the footer shows the keys.

- `cycle` advances through the types in the configured order, in insert and normal mode.
- `cycle_prev` goes back through the types, in insert and normal mode.
- `submit` saves the note, in insert and normal mode. An empty note is discarded.
- `cancel` closes the window without saving, in normal mode.

A type with `prefill = "selection"`, like `rewrite`, starts a new note with the annotated lines in a fenced block tagged with the filetype of the annotated buffer, the cursor on its first line, so the note is the replacement you want. Cycling to such a type while the input is still empty fills it the same way. Whole-file and repository notes are never prefilled.

### Picker

`<CR>` jumps to the note. The snacks.nvim picker binds the `picker.keys` actions in insert and normal mode, and lists them in its help. The `select` backend has no actions.

- `edit` opens the input on the note and updates it in place.
- `delete` deletes the selected notes, or the one under the cursor, asking first when `confirm_delete` is set unless `picker.force.delete` is.
- `delete_all` archives and clears every note after confirmation, skipped with `picker.force.delete_all`, like `clear`, and closes the picker.
- `type` moves the selected notes to the next type in the configured order.
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

The document has the following shape. Only types with at least one note appear, in the configured order. `Compared` only appears when a note was taken inside a diff view. Each note is a `###` heading carrying its location, followed by its text as free-flowing markdown. Repository notes come first in their section, then file notes sorted by file and line. Notes on a revision are marked with `~` and `@ <rev>`, whole-file notes only show the path.

```markdown
<export.prompt>

## Description

- [GENERAL]: <prompt of the general type>
- [BUG]: <prompt of the bug type>

## Compared

- `a1b2c3d4e5f` .. `LOCAL`

## [GENERAL]

### repository

Applies to the repository as a whole.

### `lua/a.lua`

Applies to the whole file.

---

## [BUG]

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

Each comment is the note's markdown as it is, without its type, since reviewers on the forge do not know what the types mean. With `external.legend = true`, or `publish({ legend = true })` for one call, each comment starts with `**[<TYPE>]**` and a blank line, and a legend is posted once per merge or pull request: `external.legend_prompt` followed by every type in use with its `external.prompt`. It is its own note: a general draft note on GitLab, a queued conversation comment on GitHub; it is recorded in the store like a note, so it is not posted twice. `external.body` changes the comment.

A note of a `prefill = "selection"` type, like `rewrite`, positioned on the new side of the diff turns its first fenced block into the forge's suggestion, which the author applies with one click: ` ```suggestion ` spanning the annotated lines on GitHub, ` ```suggestion:-0+N ` from the first annotated line on GitLab. Text around the block stays as it is. Suggestions only work in the diff, so a rewrite outside it keeps its plain block and the summary counts it.

### Staging and Submitting

Before anything is posted, a float shows the plan in the shape of the export: the target with its branches, URL and head, the totals, whether the legend is on and its text, then every note with its destination, whether it is new, an update or skipped, and the exact body that is sent. `<CR>` or `y` proceeds, `q`, `<Esc>` or `n` cancels (`external.summary_keys`). `opts.force` or `external.summary = false` skips it.

- Staging, the default, leaves everything as drafts only you can see: GitLab draft notes, or a pending GitHub review. Nothing reaches the author.
- Submitting (`opts.publish = true`, `external.submit`, or `:Annotate publish!`) asks for the verdict and an optional summary note, then publishes every draft at once, including the ones staged earlier. The chooser only lists the verdicts the forge allows you on that merge or pull request, and when Comment is the only one left it is used without asking, with the reason in the summary's Review section.
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
| `repository` | Add a note about the repository as a whole, attached to no file, like a general comment on a pull request. |
| `edit` | Edit the note under the cursor. |
| `show` | Show the notes under the cursor in a float. |
| `delete` | Delete the note under the cursor after confirmation, `delete!` without it. |
| `next` / `prev` | Jump to the next or previous note in the buffer. |
| `pick` | Pick a note of the repository and jump to it. |
| `quickfix` | Send the notes of the repository to the quickfix list. |
| `export [file\|clipboard\|both]` | Export the notes. |
| `preview` | Preview the export. |
| `publish` | Stage the notes as drafts on the merge or pull request of the current branch, `publish!` submits the review. |
| `clear` | Archive the notes of the repository and clear them after confirmation, `clear!` without it. |
| `restore` | Pick an archive of the repository and restore it. |
| `clear-archive` | Permanently delete every archive of the repository after confirmation, `clear-archive!` without it. |

## Health

`:checkhealth annotate` reports the Neovim version and whether file logging is available, whether snacks.nvim and git are available, the repository and store for the working directory, whether `glab` and `gh` are available for publishing, and whether diffview is available.
