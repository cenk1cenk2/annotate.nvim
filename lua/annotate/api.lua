local M = {}

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

---@return annotate.Annotation?
local function under_cursor()
  local location = resolve(0, vim.fn.line("."), vim.fn.line("."))
  if not location then
    return nil
  end

  local annotation = store.get_at(location.file, location.line, location.rev) or store.get_at(location.file, 0, location.rev)
  if not annotation then
    notify("No annotation under the cursor.")
  end

  return annotation
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

--- Annotates the current line, the visual selection, or the given line range.
---@param opts? { type?: string, line1?: integer, line2?: integer }
function M.add(opts)
  opts = opts or {}

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

  local location = resolve(0, math.min(line1, line2), math.max(line1, line2))
  if location then
    create(location, opts)
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
  local annotation = under_cursor()
  if not annotation then
    return
  end

  input.open({ type = annotation.type, text = annotation.text }, function(type_key, text)
    if not type_key then
      return
    end

    store.update(annotation.id, { type = type_key, text = text })
    marks.refresh()
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

--- Deletes the annotations, asking first when `confirm_delete` is set.
---@param annotations annotate.Annotation[]
---@param callback fun()
local function remove(annotations, callback)
  local function delete()
    for _, annotation in ipairs(annotations) do
      store.delete(annotation.id)
    end
    callback()
  end

  if not config.options.confirm_delete then
    return delete()
  end

  confirm(
    #annotations == 1 and ("Delete %s annotation: %s?"):format(marks.type(annotations[1]).name, vim.split(annotations[1].text, "\n", { plain = true })[1])
      or ("Delete %d annotations?"):format(#annotations),
    delete
  )
end

--- Deletes the annotation under the cursor after confirmation.
function M.delete()
  local annotation = under_cursor()
  if not annotation then
    return
  end

  remove({ annotation }, marks.refresh)
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

      remove(annotations, function()
        marks.refresh()
        picker:refresh()
      end)
    end,
  },
  delete_all = {
    desc = "Archive and clear all annotations",
    action = function(picker)
      confirm("Archive and clear all annotations?", function()
        picker:close()
        M.clear()
      end)
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

--- Archives the annotations of the repository and clears the marks.
function M.clear()
  if not root() then
    return
  end

  local archived = store.archive()
  marks.clear()

  notify(archived and ("Archived annotations to %s."):format(archived) or "There were no annotations to archive.", vim.log.levels.INFO)
end

return M
