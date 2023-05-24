local a = require("plenary.async")
local cli = require("neogit.lib.git.cli")
local config_lib = require("neogit.lib.git.config")
local input = require("neogit.lib.input")
local config = require("neogit.config")
local M = {}

local function parse_branches(branches, include_current)
  local other_branches = {}
  local pattern = "^  (.+)"
  if include_current then
    pattern = "^[* ] (.+)"
  end

  for _, b in ipairs(branches) do
    local branch_name = b:match(pattern)
    if branch_name then
      table.insert(other_branches, branch_name)
    end
  end

  return other_branches
end

function M.get_local_branches(include_current)
  local branches = cli.branch.list(config.values.sort_branches).call_sync():trim().stdout

  return parse_branches(branches, include_current)
end

function M.get_remote_branches(include_current)
  local branches = cli.branch.remotes.list(config.values.sort_branches).call_sync():trim().stdout

  return parse_branches(branches, include_current)
end

function M.get_all_branches(include_current)
  local branches = cli.branch.list(config.values.sort_branches).all.call_sync():trim().stdout

  return parse_branches(branches, include_current)
end

function M.get_upstream()
  local full_name = cli["rev-parse"].abbrev_ref().show_popup(false).args("@{upstream}").call():trim().stdout
  local current = cli.branch.current.show_popup(false).call():trim().stdout

  if #full_name > 0 and #current > 0 then
    local remote = config_lib.get("branch." .. current[1] .. ".remote").value
    if remote then
      return {
        remote = remote,
        branch = full_name[1]:sub(#remote + 2, -1),
      }
    end
  end
end

function M.prompt_for_branch(options, configuration)
  a.util.scheduler()

  options = options or M.get_local_branches()
  local c = vim.tbl_deep_extend("keep", configuration or {}, {
    truncate_remote_name = true,
    truncate_remote_name_from_options = false,
  })

  if c.truncate_remote_name_from_options and not c.truncate_remote_name then
    error(
      'invalid prompt_for_branch configuration, "truncate_remote_name_from_options" cannot be "true" when "truncate_remote_name" is "false".'
    )
    return nil
  end

  local function truncate_remote_name(branch)
    local truncated_remote_name = branch:match(".-/(.+)")
    if truncated_remote_name and truncated_remote_name ~= "" then
      return truncated_remote_name
    end

    return branch
  end

  local final_options = {}
  for _, option in ipairs(options) do
    if c.truncate_remote_name_from_options then
      table.insert(final_options, truncate_remote_name(option))
    else
      table.insert(final_options, option)
    end
  end

  local chosen = input.get_user_input_with_completion("branch > ", final_options)
  if not chosen or chosen == "" then
    return nil
  end

  if not c.truncate_remote_name_from_options and c.truncate_remote_name then
    return truncate_remote_name(chosen)
  end

  return chosen
end

function M.checkout_local()
  local branches = M.get_local_branches()

  a.util.scheduler()
  local chosen = M.prompt_for_branch(branches)
  if not chosen then
    return
  end
  cli.checkout.branch(chosen).call()
end

function M.checkout()
  local branches = M.get_all_branches()

  a.util.scheduler()
  local chosen = M.prompt_for_branch(branches)
  if not chosen then
    return
  end
  cli.checkout.branch(chosen).call()
end

function M.create()
  a.util.scheduler()
  local name = input.get_user_input("branch > ")
  if not name or name == "" then
    return
  end

  cli.branch.name(name:gsub("%s", "-")).call_interactive()

  return name
end

function M.delete()
  local branches = M.get_all_branches()

  a.util.scheduler()
  local chosen = M.prompt_for_branch(branches)
  if not chosen then
    return
  end

  cli.branch.delete.name(chosen).call_interactive()

  return chosen
end

function M.checkout_new()
  a.util.scheduler()
  local name = input.get_user_input("branch > ")
  if not name or name == "" then
    return
  end

  cli.checkout.new_branch(name:gsub("%s", "-")).call_interactive()
end

function M.current()
  local branch_name = cli.branch.current.call_sync():trim().stdout
  if #branch_name > 0 then
    return branch_name[1]
  end
  return nil
end

local FuzzyFinderBuffer = require("neogit.buffers.fuzzy_finder")
local util = require("neogit.lib.util")

function M.merge_config(branch)
  local local_branches = M.get_local_branches()
  local remote_branches = util.filter_map(M.get_remote_branches(), function(name)
    if name:match([[ ]]) then -- removes stuff like 'origin/HEAD -> origin/master'
      return nil
    else
      return name
    end
  end)

  local branches = util.merge(local_branches, remote_branches)

  return a.void(function(popup, c)
    local target = FuzzyFinderBuffer.new(branches):open_sync { prompt_prefix = "Upstream: " }
    if not target then
      return
    end

    local merge_value, remote_value
    if target:match([[/]]) then
      local target_remote, target_branch = unpack(vim.split(target, [[/]]))
      merge_value = "refs/heads/" .. target_branch
      remote_value = target_remote
    else
      merge_value = "refs/heads/" .. target
      remote_value = "."
    end

    config_lib.set("branch." .. branch .. ".merge", merge_value)
    config_lib.set("branch." .. branch .. ".remote", remote_value)

    c.value = merge_value
    popup:repaint_config()
  end)
end

return M
