local M = {
  ---@type { win: snacks.win, focused: boolean }?
  hover = nil,
}

local config = require("annotate.config")
local git = require("annotate.git")
local input = require("annotate.input")
local marks = require("annotate.marks")
local sources = require("annotate.sources")
local store = require("annotate.store")

---@param message string
---@param level? integer
local function notify(message, level)
  vim.notify(message, level or vim.log.levels.WARN, { title = config.options.notify.title })
end

---@return string?
local function root()
  local r = git.root()
  if not r then
    notify(("Not inside a git repository: %s"):format(vim.fn.getcwd()))
  end

  return r
end

---@param bufnr integer
---@param line1 integer
---@param line2 integer
---@return annotate.Location?
local function resolve(bufnr, line1, line2)
  if not root() then
    return nil
  end

  local location = sources.resolve(bufnr, line1, line2)
  if not location then
    notify("No annotation source matches this buffer.")
  end

  return location
end

--- Every annotation covering the cursor line, the whole-file ones only on line 1 when nothing else covers it.
---@return annotate.Annotation[]
local function under_cursor()
  local location = resolve(0, vim.fn.line("."), vim.fn.line("."))
  if not location then
    return {}
  end

  local annotations = vim.tbl_filter(function(annotation)
    return annotation.line > 0 and location.line >= annotation.line and location.line <= (annotation.line_end or annotation.line)
  end, store.for_file(location.file, location.rev))
  if #annotations == 0 and location.line == 1 then
    annotations = vim.tbl_filter(function(annotation)
      return annotation.line == 0
    end, store.for_file(location.file, location.rev))
  end

  if #annotations == 0 then
    notify("No annotation under the cursor.")
  end

  return annotations
end

--- Calls back with the only annotation, or lets the user choose one when they overlap, optionally offering all of them.
---@param annotations annotate.Annotation[]
---@param all boolean
---@param callback fun(chosen: annotate.Annotation[])
local function choose(annotations, all, callback)
  if #annotations == 1 then
    return callback(annotations)
  end

  local items = vim.list_extend({}, annotations)
  if all then
    table.insert(items, "All of them")
  end

  vim.ui.select(items, {
    prompt = config.options.picker.title,
    format_item = function(item)
      if type(item) == "string" then
        return item
      end

      local t = marks.type(item)

      return ("%s %s: %s (%s)"):format(t.icon, t.name, vim.split(item.text, "\n", { plain = true })[1], require("annotate.export").location(item))
    end,
  }, function(item)
    if item then
      callback(type(item) == "string" and annotations or { item })
    end
  end)
end

---@param location annotate.Location
---@param opts { type?: string }
local function create(location, opts)
  input.open({ type = opts.type or config.options.default_type or config.options.types[1].key }, function(type_key, text)
    if not type_key then
      return
    end

    store.add(vim.tbl_extend("force", location, { type = type_key, text = text }))
    marks.refresh()
  end)
end

--- Location of the given line range, the visual selection, or the current line.
---@param opts { line1?: integer, line2?: integer }
---@return annotate.Location?
local function selection(opts)
  local line1, line2 = opts.line1, opts.line2 or opts.line1
  if not line1 then
    if vim.fn.mode():match("^[vV\22]") then
      line1, line2 = vim.fn.line("v"), vim.fn.line(".")
      vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
    else
      line1 = vim.fn.line(".")
      line2 = line1
    end
  end

  return resolve(0, math.min(line1, line2), math.max(line1, line2))
end

--- Lets the user choose an annotation type, calling back with its key unless cancelled.
---@param callback fun(key: string)
local function choose_type(callback)
  local cfg = config.options.picker
  local types = config.options.types

  if (cfg.backend or (pcall(require, "snacks") and "snacks" or "select")) == "select" then
    return vim.ui.select(types, {
      prompt = "Annotation type",
      format_item = function(t)
        return ("%s %s"):format(t.icon, t.name)
      end,
    }, function(t)
      if t then
        callback(t.key)
      end
    end)
  end

  require("snacks").picker.pick({
    title = "Annotation type",
    items = vim.tbl_map(function(t)
      return { text = ("%s %s"):format(t.icon, t.name), key = t.key, preview = { text = t.prompt } }
    end, types),
    format = "text",
    preview = "preview",
    confirm = function(picker, item)
      picker:close()
      if item then
        callback(item.key)
      end
    end,
  })
end

--- Annotates the current line, the visual selection, or the given line range.
---@param opts? { type?: string, line1?: integer, line2?: integer }
function M.add(opts)
  opts = opts or {}

  local location = selection(opts)
  if location then
    create(location, opts)
  end
end

--- Like `add`, choosing the annotation type before writing the note.
---@param opts? { line1?: integer, line2?: integer }
function M.add_with_type(opts)
  local location = selection(opts or {})
  if location then
    choose_type(function(key)
      create(location, { type = key })
    end)
  end
end

--- Annotates the current file as a whole.
---@param opts? { type?: string }
function M.add_file(opts)
  local location = resolve(0, 0, 0)
  if location then
    create(location, opts or {})
  end
end

--- Edits the annotation under the cursor.
function M.edit()
  local annotations = under_cursor()
  if #annotations == 0 then
    return
  end

  choose(annotations, false, function(chosen)
    local annotation = chosen[1]

    input.open({ type = annotation.type, text = annotation.text }, function(type_key, text)
      if not type_key then
        return
      end

      store.update(annotation.id, { type = type_key, text = text })
      marks.refresh()
    end)
  end)
end

---@param prompt string
---@param callback fun()
local function confirm(prompt, callback)
  vim.ui.select({ "Yes", "No" }, { prompt = prompt }, function(choice)
    if choice == "Yes" then
      callback()
    end
  end)
end

--- Deletes the annotations, asking first when `confirm_delete` is set and it is not forced.
---@param annotations annotate.Annotation[]
---@param force? boolean
---@param callback fun()
local function remove(annotations, force, callback)
  local function delete()
    for _, annotation in ipairs(annotations) do
      store.delete(annotation.id)
    end
    callback()
  end

  if force or not config.options.confirm_delete then
    return delete()
  end

  confirm(
    #annotations == 1 and ("Delete %s annotation: %s?"):format(marks.type(annotations[1]).name, vim.split(annotations[1].text, "\n", { plain = true })[1])
      or ("Delete %d annotations?"):format(#annotations),
    delete
  )
end

--- Deletes the annotation under the cursor after confirmation, choosing first when several overlap.
---@param opts? { force?: boolean } force skips the confirmation
function M.delete(opts)
  opts = opts or {}

  local annotations = under_cursor()
  if #annotations == 0 then
    return
  end

  choose(annotations, true, function(chosen)
    remove(chosen, opts.force, marks.refresh)
  end)
end

--- Shows the annotations on the cursor line in a float, focusing the float when it is already open.
function M.show()
  local cfg = config.options.show

  if M.hover and M.hover.win:valid() and cfg.focusable then
    M.hover.focused = true

    return M.hover.win:focus()
  end

  local annotations = under_cursor()
  if #annotations == 0 then
    return
  end

  local lines = {}
  for index, annotation in ipairs(annotations) do
    local t = marks.type(annotation)

    if index > 1 then
      vim.list_extend(lines, { "", "---", "" })
    end
    vim.list_extend(lines, { ("## %s %s"):format(t.icon, t.name), "", ("`%s`"):format(require("annotate.export").location(annotation)), "" })
    if t.prompt ~= "" then
      vim.list_extend(lines, { ("_%s_"):format(t.prompt), "" })
    end
    vim.list_extend(lines, vim.split(annotation.text, "\n", { plain = true }))
  end

  local border = cfg.border or config.options.input.border

  local ok, snacks = pcall(require, "snacks")
  if not ok then
    return vim.lsp.util.open_floating_preview(lines, "markdown", {
      border = border,
      max_width = cfg.max_width,
      max_height = cfg.max_height,
      focusable = cfg.focusable,
      focus_id = "annotate",
    })
  end

  local width = 1
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  width = math.min(width, cfg.max_width)

  local height = 0
  for _, line in ipairs(lines) do
    height = height + math.max(1, math.ceil(vim.fn.strdisplaywidth(line) / width))
  end

  local hover = { focused = false }
  hover.win = snacks.win({
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = math.min(height, cfg.max_height),
    border = border,
    focusable = cfg.focusable,
    enter = false,
    text = lines,
    bo = { filetype = "markdown", modifiable = false },
    wo = { wrap = true, linebreak = true },
    keys = { q = "close", ["<Esc>"] = "close" },
    on_buf = function(self)
      pcall(vim.treesitter.start, self.buf, "markdown")
    end,
  })
  hover.win:on({ "CursorMoved", "CursorMovedI", "InsertEnter", "BufLeave" }, function(self)
    if not hover.focused then
      self:close()
    end
  end, { buffer = vim.api.nvim_get_current_buf() })
  hover.win:on("WinLeave", function(self)
    self:close()
  end, { buf = true })
  M.hover = hover
end

---@param forward boolean
local function jump(forward)
  local bufnr = vim.api.nvim_get_current_buf()
  local rows = vim.tbl_map(function(mark)
    return mark[2] + 1
  end, vim.api.nvim_buf_get_extmarks(bufnr, marks.ns, 0, -1, {}))
  rows = vim.fn.uniq(vim.fn.sort(rows, "n"))

  if #rows == 0 then
    return notify("No annotations in this buffer.", vim.log.levels.INFO)
  end

  local current = vim.fn.line(".")
  local target = forward and rows[1] or rows[#rows]
  for i = 1, #rows do
    local row = forward and rows[i] or rows[#rows - i + 1]
    if forward and row > current or not forward and row < current then
      target = row
      break
    end
  end

  vim.api.nvim_win_set_cursor(0, { target, 0 })
end

function M.next()
  jump(true)
end

function M.prev()
  jump(false)
end

---@param annotation annotate.Annotation
---@return string
local function describe(annotation)
  local t = marks.type(annotation)

  return ("%s %s %s %s"):format(t.icon, t.name, require("annotate.export").location(annotation), vim.split(annotation.text, "\n", { plain = true })[1])
end

--- Picks an annotation of the repository and jumps to it.
function M.pick()
  local r = root()
  if not r then
    return
  end

  local annotations = store.all()
  if #annotations == 0 then
    return notify("There are no annotations.", vim.log.levels.INFO)
  end

  local function open(annotation)
    vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(r, annotation.file)))
    vim.api.nvim_win_set_cursor(0, { math.min(math.max(annotation.line, 1), vim.api.nvim_buf_line_count(0)), 0 })
  end

  local cfg = config.options.picker
  local backend = cfg.backend or (pcall(require, "snacks") and "snacks" or "select")
  if backend == "select" then
    return vim.ui.select(annotations, { prompt = cfg.title, format_item = describe }, function(annotation)
      if annotation then
        open(annotation)
      end
    end)
  end

  local actions = {}
  local keys = {}
  for name, key in pairs(cfg.keys) do
    if key then
      actions["annotate_" .. name] = M.actions[name]
      keys[key] = { "annotate_" .. name, mode = { "i", "n" } }
    end
  end

  require("snacks").picker.pick({
    title = cfg.title,
    finder = function()
      return vim.tbl_map(function(annotation)
        return {
          text = describe(annotation),
          file = vim.fs.joinpath(r, annotation.file),
          pos = { math.max(annotation.line, 1), 0 },
          annotation = annotation,
        }
      end, store.all())
    end,
    actions = actions,
    win = {
      input = { keys = keys },
      list = { keys = keys },
    },
    format = "text",
    preview = "file",
    confirm = function(picker, item)
      picker:close()
      if item then
        open(item.annotation)
      end
    end,
  })
end

--- Picker actions on the selected annotations, in the shape snacks.nvim takes them.
---@type table<string, { desc: string, action: fun(picker: snacks.Picker, item?: snacks.picker.Item) }>
M.actions = {
  edit = {
    desc = "Edit annotation",
    action = function(picker, item)
      if not item then
        return
      end

      input.open({ type = item.annotation.type, text = item.annotation.text }, function(type_key, text)
        if not type_key then
          return
        end

        store.update(item.annotation.id, { type = type_key, text = text })
        marks.refresh()
        picker:refresh()
      end)
    end,
  },
  delete = {
    desc = "Delete annotations",
    action = function(picker)
      local annotations = vim.tbl_map(function(item)
        return item.annotation
      end, picker:selected({ fallback = true }))
      if #annotations == 0 then
        return
      end

      remove(annotations, config.options.picker.force.delete, function()
        marks.refresh()
        picker:refresh()
      end)
    end,
  },
  delete_all = {
    desc = "Archive and clear all annotations",
    action = function(picker)
      local function clear()
        picker:close()
        M.clear({ force = true })
      end

      if config.options.picker.force.delete_all then
        return clear()
      end

      confirm("Archive and clear all annotations?", clear)
    end,
  },
  type = {
    desc = "Cycle annotation type",
    action = function(picker)
      local types = config.options.types

      for _, item in ipairs(picker:selected({ fallback = true })) do
        local _, index = config.type(item.annotation.type)
        store.update(item.annotation.id, { type = types[(index or 0) % #types + 1].key })
      end

      marks.refresh()
      picker:refresh()
    end,
  },
}

--- Sends the annotations of the repository to the quickfix list.
function M.quickfix()
  local r = root()
  if not r then
    return
  end

  vim.fn.setqflist({}, " ", {
    title = config.options.quickfix.title,
    items = vim.tbl_map(function(annotation)
      local t = marks.type(annotation)

      return {
        filename = vim.fs.joinpath(r, annotation.file),
        lnum = math.max(annotation.line, 1),
        end_lnum = annotation.line_end,
        text = ("[%s]%s %s"):format(t.name:upper(), annotation.rev and (" @ %s"):format(annotation.rev) or "", vim.split(annotation.text, "\n", { plain = true })[1]),
      }
    end, store.all()),
  })

  if config.options.quickfix.open then
    vim.cmd.copen()
  end
end

--- Archives the annotations of the repository and clears the marks after confirmation.
---@param opts? { force?: boolean } force skips the confirmation
function M.clear(opts)
  if not root() then
    return
  end

  local function clear()
    local archived = store.archive()
    marks.clear()

    notify(archived and ("Archived annotations to %s."):format(archived) or "There were no annotations to archive.", vim.log.levels.INFO)
  end

  if (opts or {}).force then
    return clear()
  end

  confirm("Archive and clear all annotations?", clear)
end

return M
