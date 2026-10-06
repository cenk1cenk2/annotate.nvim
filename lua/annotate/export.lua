local M = {}

local config = require("annotate.config")
local git = require("annotate.git")
local store = require("annotate.store")

---@class annotate.ExportOptions
---@field to? annotate.ExportTarget
---@field prompt? string
---@field types? string[] subset of type keys to export
---@field clear? boolean archive the store after exporting

---@param annotation annotate.Annotation
---@return string
function M.location(annotation)
  if not annotation.file then
    return config.options.export.repository
  end

  local lines = ""
  if annotation.line > 0 then
    lines = annotation.line_end and ("%d-%d"):format(annotation.line, annotation.line_end) or tostring(annotation.line)
  end

  if annotation.rev then
    return lines == "" and ("%s @ %s"):format(annotation.file, annotation.rev) or ("%s:~%s @ %s"):format(annotation.file, lines, annotation.rev)
  end

  return lines == "" and annotation.file or ("%s:%s"):format(annotation.file, lines)
end

--- Orders annotations by file, then line, then creation, repository notes first.
---@param a annotate.Annotation
---@param b annotate.Annotation
---@return boolean
function M.compare(a, b)
  if a.file ~= b.file then
    return (a.file or "") < (b.file or "")
  end
  if a.line ~= b.line then
    return a.line < b.line
  end

  return a.created_at < b.created_at
end

--- Groups annotations by type and reach in the configured order, unknown ones last, each group ordered by `compare`.
---@param annotations annotate.Annotation[]
---@return { type: annotate.Type, reach: string, annotations: annotate.Annotation[] }[]
function M.sections(annotations)
  local marks = require("annotate.marks")
  local types = vim.deepcopy(config.options.types)
  local grouped = {}
  for _, annotation in ipairs(annotations) do
    if not config.type(annotation.type) and not grouped[annotation.type] then
      table.insert(types, marks.type(annotation))
    end

    local reach = marks.reach(annotation)
    grouped[annotation.type] = grouped[annotation.type] or {}
    grouped[annotation.type][reach] = grouped[annotation.type][reach] or {}
    table.insert(grouped[annotation.type][reach], annotation)
  end

  local sections = {}
  for _, t in ipairs(types) do
    local reaches = vim.list_extend({}, t.reaches)
    for reach in vim.spairs(grouped[t.key] or {}) do
      if not vim.list_contains(reaches, reach) then
        table.insert(reaches, reach)
      end
    end

    for _, reach in ipairs(reaches) do
      local group = grouped[t.key] and grouped[t.key][reach]
      if group then
        table.sort(group, M.compare)
        table.insert(sections, { type = t, reach = reach, annotations = group })
      end
    end
  end

  return sections
end

--- Renders annotations into the markdown document handed to an agent.
---@param annotations annotate.Annotation[]
---@param opts? annotate.ExportOptions
---@return string
function M.render(annotations, opts)
  opts = opts or {}

  local cfg = config.options.export
  if cfg.format then
    return cfg.format(annotations, opts, config.options)
  end

  local sections = vim.tbl_filter(function(section)
    return not opts.types or vim.list_contains(opts.types, section.type.key)
  end, M.sections(annotations))

  local lines = { opts.prompt or config.text("export", "prompt", sections), "", ("## %s"):format(cfg.headings.description), "" }
  local reaches = {}
  for _, section in ipairs(sections) do
    local prompt = config.prompt(section.type, "export", section.reach)
    table.insert(lines, prompt ~= "" and ("- %s: %s"):format(cfg.label(section.type, section.reach), prompt) or ("- %s"):format(cfg.label(section.type, section.reach)))
    if cfg.reach and cfg.reach[section.reach] and not vim.list_contains(reaches, section.reach) then
      table.insert(reaches, section.reach)
    end
  end

  if #reaches > 0 then
    vim.list_extend(lines, { "", ("## %s"):format(cfg.headings.reach), "" })
    for _, reach in ipairs(reaches) do
      table.insert(lines, ("- %s: %s"):format(reach, cfg.reach[reach]))
    end
  end

  local compared = {}
  for _, section in ipairs(sections) do
    for _, annotation in ipairs(section.annotations) do
      if annotation.context then
        local pair = ("- `%s` .. `%s`"):format(annotation.context.left, annotation.context.right)
        if not vim.list_contains(compared, pair) then
          table.insert(compared, pair)
        end
      end
    end
  end

  if #compared > 0 then
    vim.list_extend(lines, { "", ("## %s"):format(cfg.headings.compared), "" })
    vim.list_extend(lines, compared)
  end

  for index, section in ipairs(sections) do
    if index > 1 then
      vim.list_extend(lines, { "", cfg.separator })
    end
    vim.list_extend(lines, { "", ("## %s"):format(cfg.label(section.type, section.reach)), "" })

    for i, annotation in ipairs(section.annotations) do
      if i > 1 then
        table.insert(lines, "")
      end
      vim.list_extend(lines, { cfg.heading(annotation, section.type, M.location(annotation)), "" })
      vim.list_extend(lines, vim.split(annotation.text, "\n", { plain = true }))
    end
  end

  return table.concat(lines, "\n") .. "\n"
end

--- Exports the annotations of the current repository and delivers the markdown.
---@param opts? annotate.ExportOptions
---@return string? markdown, nil when there was nothing to export
function M.export(opts)
  opts = opts or {}

  local annotations = vim.tbl_filter(function(annotation)
    return not opts.types or vim.list_contains(opts.types, annotation.type)
  end, store.all())

  if #annotations == 0 then
    vim.notify("There are no annotations to export.", vim.log.levels.WARN, { title = config.options.notify.title })

    return nil
  end

  local to = opts.to or config.options.export.to
  if type(to) ~= "function" and not vim.list_contains({ "file", "clipboard", "both" }, to) then
    error(("annotate: unknown export target: %s"):format(to))
  end

  local markdown = M.render(annotations, opts)

  if type(to) == "function" then
    to(markdown, annotations)
  else
    local path
    if to == "file" or to == "both" then
      path = vim.fs.joinpath(config.options.export.dir, config.resolve(config.options.export.filename, vim.fs.basename(git.workspace())))
      vim.fn.mkdir(vim.fs.dirname(path), "p")
      local file = assert(io.open(path, "w"))
      file:write(markdown)
      file:close()
    end

    if to == "clipboard" or to == "both" then
      local message = path and ("%s\n\n@%s"):format(config.text("export", "clipboard_message", path), path) or markdown
      vim.fn.setreg("+", message)
      vim.fn.setreg("*", message)
    end

    vim.notify(
      path and ("Exported %d annotations to %s."):format(#annotations, path) or ("Copied %d annotations to the clipboard."):format(#annotations),
      vim.log.levels.INFO,
      { title = config.options.notify.title }
    )
  end

  if opts.clear then
    store.archive()
    require("annotate.marks").clear()
  end

  return markdown
end

--- Shows the export markdown without delivering it.
---@param opts? annotate.ExportOptions
function M.preview(opts)
  local markdown = M.render(store.all(), opts)
  local lines = vim.split(markdown, "\n", { plain = true })

  local ok, snacks = pcall(require, "snacks")
  if not ok then
    vim.cmd.new()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
    vim.bo.buftype = "nofile"
    vim.bo.bufhidden = "wipe"
    vim.bo.modifiable = false
    vim.bo.filetype = "markdown"

    return
  end

  snacks.win({
    position = "float",
    width = 0.8,
    height = 0.8,
    border = config.options.input.border,
    title = " annotate ",
    title_pos = "center",
    enter = true,
    text = lines,
    ft = "markdown",
    bo = { modifiable = false },
    wo = { wrap = true, linebreak = true },
    keys = { q = "close" },
  })
end

return M
