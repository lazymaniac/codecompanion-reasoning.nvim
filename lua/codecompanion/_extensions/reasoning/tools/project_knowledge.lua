local log_ok, log = pcall(require, 'codecompanion.utils.log')
if not log_ok then
  log = {
    debug = function(...) end,
    warn = function(...)
      vim.notify(string.format(...), vim.log.levels.WARN)
    end,
    error = function(...)
      vim.notify(string.format(...), vim.log.levels.ERROR)
    end,
  }
end

local function find_project_root()
  return vim.fn.getcwd()
end

-- Only used when we actually write to the file (on user approval).
local function ensure_knowledge_file()
  local project_root = find_project_root()
  local codecompanion_dir = project_root .. '/.codecompanion'
  local knowledge_file = codecompanion_dir .. '/project-knowledge.md'

  if vim.fn.isdirectory(codecompanion_dir) == 0 then
    vim.fn.mkdir(codecompanion_dir, 'p')
  end

  if vim.fn.filereadable(knowledge_file) == 0 then
    local initial_content = [[# Project Knowledge

## Project Overview
*This section will be updated with project information*

## Directory Structure
*Key directories and their purposes will be documented here*

## Changelog
*Recent project changes will be logged here*

## Current Features in Development
*Active features being worked on*

]]
    local file = io.open(knowledge_file, 'w')
    if file then
      file:write(initial_content)
      file:close()
    end
  end

  return knowledge_file
end

local function get_knowledge_file_path()
  local project_root = find_project_root()
  return project_root .. '/.codecompanion/project-knowledge.md'
end

local function get_recent_changed_files()
  -- Get recently changed files from git
  local handle = io.popen('git diff --name-only HEAD~3..HEAD 2>/dev/null')
  if not handle then
    return {}
  end

  local files = {}
  for line in handle:lines() do
    table.insert(files, line)
  end
  handle:close()

  return files
end

local function format_knowledge_preview(proposal)
  local preview = string.format('Description: %s', proposal.description)

  if proposal.files and #proposal.files > 0 then
    preview = preview .. string.format('\nFiles: %s', table.concat(proposal.files, ', '))
  end

  return preview
end

local function store_changelog_entry(knowledge_file, description, files)
  local date = os.date('%Y-%m-%d')
  local entry = string.format('### %s\n- **%s**', date, description)

  if files and #files > 0 then
    entry = entry .. string.format(' (%d files changed)', #files)
    for _, file in ipairs(files) do
      entry = entry .. string.format('\n  - `%s`', file)
    end
  end
  entry = entry .. '\n\n'

  -- Read current content
  local file = io.open(knowledge_file, 'r')
  if not file then
    return false
  end

  local content = file:read('*all')
  file:close()

  -- Find changelog section and insert new entry
  local changelog_pattern = '## Changelog\n'
  local changelog_pos = content:find(changelog_pattern)

  if changelog_pos then
    local insert_pos = changelog_pos + #changelog_pattern
    local new_content = content:sub(1, insert_pos) .. entry .. content:sub(insert_pos + 1)

    -- Write updated content
    file = io.open(knowledge_file, 'w')
    if file then
      file:write(new_content)
      file:close()
      return true
    end
  end

  return false
end

local function show_knowledge_approval_dialog(proposal, callback)
  local preview = format_knowledge_preview(proposal)

  vim.schedule(function()
    vim.ui.select({ '✓ Approve', '✗ Reject' }, {
      prompt = 'Store this knowledge?\n\n' .. preview,
      format_item = function(item)
        return item
      end,
    }, function(choice)
      if choice == '✓ Approve' then
        local knowledge_file = ensure_knowledge_file()
        local success = store_changelog_entry(knowledge_file, proposal.description, proposal.files)

        if success then
          callback('✓ Knowledge stored: ' .. proposal.description)
        else
          callback('✗ Failed to store knowledge')
        end
      else
        callback('Knowledge update cancelled')
      end
    end)
  end)
end

-- Load project knowledge for auto-injection into chat context
local function load_project_knowledge()
  local knowledge_file = get_knowledge_file_path()
  if vim.fn.filereadable(knowledge_file) == 0 then return nil end

  local file = io.open(knowledge_file, 'r')
  if not file then return nil end
  local content = file:read('*all')
  file:close()

  if not content or content == '' then return nil end
  -- Return file content as-is; injection will place it as a hidden system message
  return content
end

-- Auto-load project context - ONLY from our project knowledge file
local function auto_load_project_context()
  -- Only load from our project knowledge file, ignore other AI context files
  local project_context = load_project_knowledge()

  return project_context
end

-- Export functions for use by chat hooks
_G.CodeCompanionProjectKnowledge = {
  load_project_knowledge = load_project_knowledge,
  auto_load_project_context = auto_load_project_context,
}

return {
  name = 'project_knowledge',

  opts = {},

  cmds = {
    function(self, args, input, callback)
      -- Only for updating/storing knowledge, not loading
      local proposal = {
        description = args.description,
        files = args.files or get_recent_changed_files(),
      }

      if not proposal.description or proposal.description == '' then
        callback({
          status = 'error',
          data = 'Error: Description is required',
        })
        return
      end

      -- Show user approval dialog
      show_knowledge_approval_dialog(proposal, function(result)
        local is_ok = type(result) == 'string' and result:match('^%s*✓') ~= nil
        callback({
          status = is_ok and 'success' or 'error',
          data = result,
        })
      end)
    end,
  },

  schema = {
    type = 'function',
    ['function'] = {
      name = 'project_knowledge',
      description = 'Update project knowledge with new information (project context is auto-loaded at chat start)',
      parameters = {
        type = 'object',
        properties = {
          description = {
            type = 'string',
            description = 'Brief description of what was accomplished or learned',
          },
          files = {
            type = 'array',
            items = { type = 'string' },
            description = 'List of files involved in this change (optional, will auto-detect from git if not provided)',
          },
        },
        required = { 'description' },
        additionalProperties = false,
      },
      strict = true,
    },
  },

  output = {
    success = function(self, agent, cmd, stdout)
      local chat = agent.chat
      local result = vim.iter(stdout):flatten():join('\n')
      return chat:add_tool_output(self, result, result)
    end,
    error = function(self, agent, cmd, stderr)
      local chat = agent.chat
      local errors = vim.iter(stderr):flatten():join('\n')
      return chat:add_tool_output(self, errors)
    end,
  },
}
