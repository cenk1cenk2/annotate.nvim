---@class annotate.Publisher
local M = {}

M.name = "gitlab"

M.label = "GitLab"

M.target = "Merge request"

M.permissions = [[
query($project: ID!, $iid: String!) {
  currentUser { username }
  project(fullPath: $project) {
    mergeRequest(iid: $iid) {
      discussionLocked
      userPermissions { createNote canApprove }
      approvedBy { nodes { username } }
      reviewers { nodes { username mergeRequestInteraction { reviewState } } }
    }
  }
}]]

M.add_reviewer = [[
mutation($project: ID!, $iid: String!, $username: String!) {
  mergeRequestSetReviewers(input: { projectPath: $project, iid: $iid, reviewerUsernames: [$username], operationMode: APPEND }) { errors }
}]]

M.request_changes = [[
mutation($project: ID!, $iid: String!) {
  mergeRequestRequestChanges(input: { projectPath: $project, iid: $iid }) { errors }
}]]

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
    vim.list_extend(cmd, { "--header", "Content-Type: application/json", "--input", "-" })
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

--- Runs a GraphQL query or mutation on the host of the remote, raising on the errors it returns.
---@param remote annotate.Remote
---@param query string
---@param variables table
---@return table
function M.graphql(remote, query, variables)
  local result = require("annotate.publishers").json({
    require("annotate.config").options.external.gitlab_cli,
    "api",
    "--hostname",
    remote.host,
    "graphql",
    "--header",
    "Content-Type: application/json",
    "--input",
    "-",
  }, { query = query, variables = variables }) or {}
  if result.errors then
    error(("annotate: GitLab GraphQL failed: %s"):format(vim.json.encode(result.errors)), 0)
  end

  return result.data or {}
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

--- From the permissions of the user on the merge request: Comment while the user can write notes; Approve while the user can approve and has not,
--- Unapprove once the user has approved; Request changes unless the user already requested them, confirming to add the user as a reviewer first, which GitLab requires.
function M.verdicts(target)
  local data = M.graphql(target.remote, M.permissions, { project = target.remote.path, iid = tostring(target.id) })
  local mr = vim.tbl_get(data, "project", "mergeRequest") or error(("annotate: GitLab returned no merge request %s"):format(target.reference), 0)
  local username = vim.tbl_get(data, "currentUser", "username")

  if not mr.userPermissions.createNote then
    error(("annotate: you can not comment on %s%s"):format(target.reference, mr.discussionLocked and ": its discussion is locked" or ""), 0)
  end

  local approved = vim.iter(vim.tbl_get(mr, "approvedBy", "nodes") or {}):any(function(user)
    return user.username == username
  end)
  local reviewer = vim.iter(vim.tbl_get(mr, "reviewers", "nodes") or {}):find(function(user)
    return user.username == username
  end)

  local verdicts = { { key = "comment", label = "Comment" } }
  local reasons = {}
  if approved then
    table.insert(verdicts, { key = "unapprove", label = "Unapprove" })
  elseif mr.userPermissions.canApprove then
    table.insert(verdicts, { key = "approve", label = "Approve" })
  else
    table.insert(reasons, "approving is not available: you can not approve this merge request")
  end
  if not reviewer then
    target.joins_as_reviewer = username
    table.insert(verdicts, {
      key = "request_changes",
      label = "Request changes",
      confirm = ("Requesting changes needs you as a reviewer, add yourself as a reviewer of %s?"):format(target.reference),
    })
  elseif vim.tbl_get(reviewer, "mergeRequestInteraction", "reviewState") ~= "REQUESTED_CHANGES" then
    table.insert(verdicts, { key = "request_changes", label = "Request changes" })
  end

  return verdicts, #reasons > 0 and table.concat(reasons, "; ") or nil
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
  elseif verdict == "request_changes" then
    if target.joins_as_reviewer then
      local added = vim.tbl_get(
        M.graphql(target.remote, M.add_reviewer, { project = target.remote.path, iid = tostring(target.id), username = target.joins_as_reviewer }),
        "mergeRequestSetReviewers",
        "errors"
      ) or {}
      if #added > 0 then
        error(("annotate: adding you as a reviewer of %s failed: %s"):format(target.reference, table.concat(added, ", ")), 0)
      end
    end
    local errors = vim.tbl_get(M.graphql(target.remote, M.request_changes, { project = target.remote.path, iid = tostring(target.id) }), "mergeRequestRequestChanges", "errors")
      or {}
    if #errors > 0 then
      error(("annotate: requesting changes on %s failed: %s"):format(target.reference, table.concat(errors, ", ")), 0)
    end
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
