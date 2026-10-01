---@class annotate.Publisher
local M = {}

M.name = "github"

M.label = "GitHub"

M.target = "Pull request"

M.verdicts = {
  { key = "comment", label = "Comment" },
  { key = "approve", label = "Approve" },
  { key = "request_changes", label = "Request changes" },
}

M.thread = [[
mutation($review: ID!, $path: String!, $body: String!, $line: Int, $side: DiffSide, $startLine: Int, $startSide: DiffSide, $subjectType: PullRequestReviewThreadSubjectType) {
  addPullRequestReviewThread(input: { pullRequestReviewId: $review, path: $path, body: $body, line: $line, side: $side, startLine: $startLine, startSide: $startSide, subjectType: $subjectType }) {
    thread { id comments(first: 1) { nodes { id databaseId url } } }
  }
}]]

function M.match(url)
  return require("annotate.publishers").parse_remote(url) == "github.com"
end

--- Calls `gh api` on the host of the remote, sending `body` as JSON, with every page flattened into one list when paginating.
---@param remote annotate.Remote
---@param endpoint string
---@param opts? { method?: string, body?: table, paginate?: boolean, attempt?: boolean } attempt returns nil and the stderr instead of raising
---@return any, string?
function M.api(remote, endpoint, opts)
  opts = opts or {}

  local cmd = { require("annotate.config").options.external.github_cli, "api", "--hostname", remote.host, endpoint }
  if opts.method then
    vim.list_extend(cmd, { "--method", opts.method })
  end
  if opts.body then
    vim.list_extend(cmd, { "--input", "-" })
  end
  if opts.paginate then
    vim.list_extend(cmd, { "--paginate", "--slurp" })
  end

  local publishers = require("annotate.publishers")
  if opts.attempt then
    return publishers.attempt(cmd, opts.body)
  end

  local result = publishers.json(cmd, opts.body)
  if opts.paginate then
    return vim.iter(result or {}):flatten():totable()
  end

  return result
end

---@param target annotate.Target
---@param path? string
---@return string
local function pulls(target, path)
  return ("repos/%s/pulls/%d%s"):format(target.remote.path, target.id, path or "")
end

---@param ... string?
---@return string
local function join(...)
  return table.concat(
    vim.tbl_filter(function(part)
      return part ~= ""
    end, { ... }),
    "\n\n"
  )
end

function M.resolve(remote)
  local publishers = require("annotate.publishers")

  local pr = publishers.json({
    require("annotate.config").options.external.github_cli,
    "pr",
    "list",
    "--repo",
    ("%s/%s"):format(remote.host, remote.path),
    "--head",
    remote.branch,
    "--state",
    "open",
    "--limit",
    "1",
    "--json",
    "id,number,title,url,headRefName,baseRefName,headRefOid,baseRefOid",
  })[1]
  if not pr then
    return nil
  end

  local target = {
    id = pr.number,
    reference = ("#%d"):format(pr.number),
    title = pr.title,
    url = pr.url,
    branch = pr.headRefName,
    target_branch = pr.baseRefName,
    head = pr.headRefOid,
    base = publishers.git({ "merge-base", pr.baseRefOid, pr.headRefOid }) or pr.baseRefOid,
    ids = { pr_node_id = pr.id },
    remote = remote,
  }
  target.files = vim.tbl_map(function(file)
    return { new_path = file.filename, old_path = file.previous_filename or file.filename, lines = publishers.parse_diff(file.patch) }
  end, M.api(remote, pulls(target, "/files?per_page=100"), { paginate = true }))

  return target
end

function M.drafts(target)
  local login = M.api(target.remote, "user").login
  target.review = vim.iter(M.api(target.remote, pulls(target, "/reviews?per_page=100"), { paginate = true })):find(function(review)
    return review.state == "PENDING" and review.user.login == login
  end)

  local drafts = {}
  if target.review then
    drafts[tostring(target.review.id)] = true
    for _, comment in ipairs(M.api(target.remote, pulls(target, ("/reviews/%d/comments?per_page=100"):format(target.review.id)), { paginate = true })) do
      drafts[tostring(comment.id)] = true
    end
  end

  return drafts
end

function M.route(item)
  local publishers = require("annotate.publishers")

  local suggestion = publishers.suggest(item, "suggestion")
  if suggestion then
    return "suggestion", suggestion
  elseif item.kind == "line" then
    return "inline", item.body
  elseif item.kind == "file" and item.in_diff then
    return "file", (item.annotation.line == 0 and not item.annotation.rev) and item.body or publishers.located(item)
  end

  return "body", item.kind == "repository" and item.body or publishers.located(item)
end

function M.post(target, items, record)
  local publishers = require("annotate.publishers")

  if #items == 0 then
    return
  end

  local bodies = vim.tbl_filter(function(item)
    return item.destination == "body"
  end, items)
  local body = table.concat(
    vim.tbl_map(function(item)
      return item.body
    end, bodies),
    "\n\n"
  )

  if not target.review then
    target.review = M.api(target.remote, pulls(target, "/reviews"), { method = "POST", body = { commit_id = target.head, body = body ~= "" and body or nil } })
  elseif body ~= "" then
    target.review = M.api(target.remote, pulls(target, ("/reviews/%d"):format(target.review.id)), { method = "PUT", body = { body = join(target.review.body or "", body) } })
  end

  for _, item in ipairs(bodies) do
    record(item, { id = target.review.id, review_id = target.review.id, review_node_id = target.review.node_id, comment_url = target.review.html_url })
  end

  for _, item in ipairs(items) do
    if item.destination ~= "body" then
      local side = item.side == "old" and "LEFT" or "RIGHT"
      local variables = { review = target.review.node_id, path = item.path, body = item.body }
      if item.destination == "file" then
        variables.subjectType = "FILE"
      else
        variables.line = item.line_end
        variables.side = side
        if item.line_end > item.line then
          variables.startLine = item.line
          variables.startSide = side
        end
      end

      local result = publishers.json({ require("annotate.config").options.external.github_cli, "api", "--hostname", target.remote.host, "graphql", "--input", "-" }, {
        query = M.thread,
        variables = variables,
      })
      local thread = vim.tbl_get(result or {}, "data", "addPullRequestReviewThread", "thread")
      local comment = thread and thread.comments.nodes[1] or error(("annotate: GitHub created no review thread for %s: %s"):format(item.location, vim.json.encode(result)), 0)

      record(item, {
        id = comment.databaseId,
        comment_id = comment.databaseId,
        comment_node_id = comment.id,
        thread_node_id = thread.id,
        review_id = target.review.id,
        review_node_id = target.review.node_id,
        comment_url = comment.url,
      })
    end
  end
end

function M.update(target, item, entry)
  local publishers = require("annotate.publishers")

  local function fail(endpoint, err)
    if publishers.missing(err) then
      return nil
    end
    error(("gh api %s failed: %s"):format(endpoint, err), 0)
  end

  if entry.comment_id then
    local endpoint = ("repos/%s/pulls/comments/%d"):format(target.remote.path, entry.comment_id)
    local comment, err = M.api(target.remote, endpoint, { method = "PATCH", body = { body = item.body }, attempt = true })
    if err then
      return fail(endpoint, err)
    end

    return { comment_url = comment.html_url }
  end

  local endpoint = pulls(target, ("/reviews/%d"):format(entry.review_id or entry.id))
  local review = target.review and target.review.id == (entry.review_id or entry.id) and target.review
  if not review then
    local err
    review, err = M.api(target.remote, endpoint, { attempt = true })
    if err then
      return fail(endpoint, err)
    end
  end

  local first, last = (review.body or ""):find(entry.body or "", 1, true)
  if not (entry.body and first) then
    return nil
  end

  local updated, err = M.api(target.remote, endpoint, {
    method = "PUT",
    body = { body = review.body:sub(1, first - 1) .. item.body .. review.body:sub(last + 1) },
    attempt = true,
  })
  if err then
    return fail(endpoint, err)
  end
  if target.review and target.review.id == updated.id then
    target.review = updated
  end

  return {}
end

function M.submit(target, verdict, note)
  local event = verdict:upper()

  if target.review then
    M.api(target.remote, pulls(target, ("/reviews/%d/events"):format(target.review.id)), {
      method = "POST",
      body = { event = event, body = join(note or "", target.review.body or "") },
    })
  else
    M.api(target.remote, pulls(target, "/reviews"), { method = "POST", body = { commit_id = target.head, event = event, body = note } })
  end
end

return M
