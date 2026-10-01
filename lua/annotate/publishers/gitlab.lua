---@class annotate.Publisher
local M = {}

M.name = "gitlab"

M.label = "GitLab"

M.target = "Merge request"

M.verdicts = {
  { key = "comment", label = "Comment" },
  { key = "approve", label = "Approve" },
}

function M.match(url)
  local host = require("annotate.publishers").parse_remote(url)

  return host ~= nil and host:find("gitlab", 1, true) ~= nil
end

--- Calls `glab api` on the host of the target, sending `body` as JSON.
---@param remote annotate.Remote
---@param endpoint string relative to the project
---@param opts? { method?: string, body?: table, paginate?: boolean }
---@return any
function M.api(remote, endpoint, opts)
  opts = opts or {}

  local cmd = {
    require("annotate.config").options.publish.gitlab_cli,
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

  return require("annotate.publishers").json(cmd, opts.body)
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
    head = mr.diff_refs.head_sha,
    base = mr.diff_refs.base_sha,
    diff_refs = mr.diff_refs,
    files = vim.tbl_map(function(diff)
      return { new_path = diff.new_path, old_path = diff.old_path, lines = publishers.parse_diff(diff.diff) }
    end, M.api(remote, ("merge_requests/%d/diffs"):format(mr.iid), { paginate = true }) or {}),
    remote = remote,
  }
end

function M.drafts(target)
  local drafts = {}
  for _, draft in ipairs(M.api(target.remote, ("merge_requests/%d/draft_notes"):format(target.id), { paginate = true }) or {}) do
    drafts[tostring(draft.id)] = true
  end

  return drafts
end

function M.route(item)
  if item.kind == "line" then
    return "inline", item.body
  end

  return "general", item.kind == "repository" and item.body or require("annotate.publishers").located(item)
end

function M.post(target, items, record)
  for _, item in ipairs(items) do
    local body = { note = item.body }
    if item.destination == "inline" then
      body.position = {
        position_type = "text",
        base_sha = target.diff_refs.base_sha,
        start_sha = target.diff_refs.start_sha,
        head_sha = target.diff_refs.head_sha,
        new_path = item.path,
        old_path = item.old_path,
        new_line = item.new_line,
        old_line = item.old_line,
      }
    end

    local draft = M.api(target.remote, ("merge_requests/%d/draft_notes"):format(target.id), { method = "POST", body = body })
    record(item, draft.id)
  end
end

function M.submit(target, verdict, note)
  local drafts = M.api(target.remote, ("merge_requests/%d/draft_notes"):format(target.id), { paginate = true }) or {}

  M.api(target.remote, ("merge_requests/%d/draft_notes/bulk_publish"):format(target.id), { method = "POST" })

  if note then
    M.api(target.remote, ("merge_requests/%d/notes"):format(target.id), { method = "POST", body = { body = note } })
  end

  if verdict == "approve" then
    M.api(target.remote, ("merge_requests/%d/approve"):format(target.id), { method = "POST", body = { sha = target.head } })
  end

  local notes = M.api(target.remote, ("merge_requests/%d/notes?sort=desc&order_by=created_at&per_page=100"):format(target.id)) or {}
  local urls = {}
  for _, draft in ipairs(drafts) do
    local published = vim.iter(notes):find(function(n)
      return not n.system and n.body == draft.note
    end)
    if published then
      urls[tostring(draft.id)] = ("%s#note_%d"):format(target.url, published.id)
    end
  end

  return urls
end

return M
