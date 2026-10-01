---@class annotate.Publisher
local M = {}

M.name = "gitlab"

M.label = "GitLab"

M.target = "Merge request"

function M.match(url)
  local host = require("annotate.publishers").parse_remote(url)

  return host ~= nil and host:find("gitlab", 1, true) ~= nil
end

--- Calls `glab api` on the host of the target, sending `body` as JSON.
---@param remote annotate.Remote
---@param endpoint string relative to the project
---@param opts? { method?: string, body?: table, paginate?: boolean, attempt?: boolean } attempt returns nil and the stderr instead of raising
---@return any, string?
function M.api(remote, endpoint, opts)
  opts = opts or {}

  local cmd = {
    require("annotate.config").options.external.gitlab_cli,
    "api",
    "--hostname",
    remote.host,
    ("projects/%s/%s"):format(vim.uri_encode(remote.path, "rfc2396"), endpoint),
  }
  if opts.method then
    vim.list_extend(cmd, { "--method", opts.method })
  end
  if opts.body then
    vim.list_extend(cmd, { "--input", "-" })
  end
  if opts.paginate then
    table.insert(cmd, "--paginate")
  end

  local publishers = require("annotate.publishers")
  if opts.attempt then
    return publishers.attempt(cmd, opts.body)
  end

  return publishers.json(cmd, opts.body)
end

function M.resolve(remote)
  local publishers = require("annotate.publishers")

  local mr = M.api(remote, ("merge_requests?source_branch=%s&state=opened"):format(vim.uri_encode(remote.branch, "rfc2396")))[1]
  if not mr then
    return nil
  end

  mr = M.api(remote, ("merge_requests/%d"):format(mr.iid))

  return {
    id = mr.iid,
    reference = ("!%d"):format(mr.iid),
    title = mr.title,
    url = mr.web_url,
    branch = mr.source_branch,
    target_branch = mr.target_branch,
    draft = mr.draft,
    head = mr.diff_refs.head_sha,
    base = mr.diff_refs.base_sha,
    diff_refs = mr.diff_refs,
    ids = { mr_id = mr.id, iid = mr.iid, project_id = mr.project_id },
    files = vim.tbl_map(function(diff)
      return { new_path = diff.new_path, old_path = diff.old_path, lines = publishers.parse_diff(diff.diff) }
    end, M.api(remote, ("merge_requests/%d/diffs"):format(mr.iid), { paginate = true }) or {}),
    remote = remote,
  }
end

--- Comment always; Approve while the user can approve and has not; Unapprove once the user has approved.
function M.verdicts(target)
  local approvals = M.api(target.remote, ("merge_requests/%d/approvals"):format(target.id))
  local has = approvals.user_has_approved
  if has == nil then
    local username = require("annotate.publishers").json({ require("annotate.config").options.external.gitlab_cli, "api", "--hostname", target.remote.host, "user" }).username
    has = vim.iter(approvals.approved_by or {}):any(function(approval)
      return approval.user.username == username
    end)
  end

  local verdicts = { { key = "comment", label = "Comment" } }
  if has then
    table.insert(verdicts, { key = "unapprove", label = "Unapprove" })
  elseif approvals.user_can_approve ~= false then
    table.insert(verdicts, { key = "approve", label = "Approve" })
  end

  return verdicts, approvals.user_can_approve == false and not has and "approving is not available: you can not approve this merge request" or nil
end

function M.drafts(target)
  local drafts = {}
  for _, draft in ipairs(M.api(target.remote, ("merge_requests/%d/draft_notes"):format(target.id), { paginate = true }) or {}) do
    drafts[tostring(draft.id)] = true
  end

  return drafts
end

function M.route(item)
  local publishers = require("annotate.publishers")

  local suggestion = publishers.suggest(item, ("suggestion:-0+%d"):format((item.line_end or 0) - (item.line or 0)))
  if suggestion then
    return "suggestion", suggestion
  elseif item.kind == "line" then
    return "inline", item.body
  end

  return "general", item.kind == "repository" and item.body or publishers.located(item)
end

--- GitLab's code for a diff line: the SHA-1 of the path, then the line's old and new position.
---@param path string
---@param line annotate.DiffLine
---@return string
function M.line_code(path, line)
  return ("%s_%d_%d"):format(require("annotate.publishers").sha1(path), line.old_pos, line.new_pos)
end

--- `position.line_range` spanning a multi-line note, so the comment covers the whole range.
---@param item annotate.PublishItem
---@return table
function M.line_range(item)
  local function point(line)
    return {
      line_code = M.line_code(item.path, line),
      type = line.type,
      old_line = line.type ~= "new" and line.old_pos or nil,
      new_line = line.type ~= "old" and line.new_pos or nil,
    }
  end

  return { start = point(item.first), ["end"] = point(item.last) }
end

function M.post(target, items, record)
  for _, item in ipairs(items) do
    local body = { note = item.body }
    if item.destination == "inline" or item.destination == "suggestion" then
      body.position = {
        position_type = "text",
        base_sha = target.diff_refs.base_sha,
        start_sha = target.diff_refs.start_sha,
        head_sha = target.diff_refs.head_sha,
        new_path = item.path,
        old_path = item.old_path,
        new_line = item.new_line,
        old_line = item.old_line,
        line_range = item.line_end > item.line and M.line_range(item) or nil,
      }
    end

    local draft = M.api(target.remote, ("merge_requests/%d/draft_notes"):format(target.id), { method = "POST", body = body })
    record(item, { id = draft.id, draft_id = draft.id, discussion_id = draft.discussion_id })
  end
end

function M.update(target, item, entry)
  local publishers = require("annotate.publishers")

  local endpoint, body
  if entry.state == "draft" then
    endpoint, body = ("merge_requests/%d/draft_notes/%d"):format(target.id, entry.draft_id or entry.id), { note = item.body }
  elseif entry.note_id then
    endpoint, body = ("merge_requests/%d/notes/%d"):format(target.id, entry.note_id), { body = item.body }
  else
    return nil
  end

  local _, err = M.api(target.remote, endpoint, { method = "PUT", body = body, attempt = true })
  if err then
    if publishers.missing(err) then
      return nil
    end
    error(("glab api %s failed: %s"):format(endpoint, err), 0)
  end

  return {}
end

function M.submit(target, verdict, note)
  local drafts = M.api(target.remote, ("merge_requests/%d/draft_notes"):format(target.id), { paginate = true }) or {}

  M.api(target.remote, ("merge_requests/%d/draft_notes/bulk_publish"):format(target.id), { method = "POST" })

  if note then
    M.api(target.remote, ("merge_requests/%d/notes"):format(target.id), { method = "POST", body = { body = note } })
  end

  if verdict == "approve" then
    M.api(target.remote, ("merge_requests/%d/approve"):format(target.id), { method = "POST", body = { sha = target.head } })
  elseif verdict == "unapprove" then
    M.api(target.remote, ("merge_requests/%d/unapprove"):format(target.id), { method = "POST" })
  end

  local notes = {}
  for _, discussion in ipairs(M.api(target.remote, ("merge_requests/%d/discussions?per_page=100"):format(target.id), { paginate = true }) or {}) do
    for _, n in ipairs(discussion.notes or {}) do
      if not n.system then
        table.insert(notes, { id = n.id, body = n.body, discussion_id = discussion.id })
      end
    end
  end

  local published = {}
  for _, draft in ipairs(drafts) do
    local found = vim.iter(notes):rev():find(function(n)
      return n.body == draft.note
    end)
    if found then
      published[tostring(draft.id)] = { note_id = found.id, discussion_id = found.discussion_id, comment_url = ("%s#note_%d"):format(target.url, found.id) }
    end
  end

  return published
end

return M
