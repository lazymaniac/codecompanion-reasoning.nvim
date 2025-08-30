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
  local root_patterns = { '.git', 'package.json', 'Cargo.toml', 'pyproject.toml', 'go.mod', '.project' }
  
  local current_dir = vim.fn.getcwd()
  local path_parts = vim.split(current_dir, '/')
  
  for i = #path_parts, 1, -1 do
    local test_path = '/' .. table.concat(path_parts, '/', 1, i)
    
    for _, pattern in ipairs(root_patterns) do
      if vim.fn.filereadable(test_path .. '/' .. pattern) == 1 or vim.fn.isdirectory(test_path .. '/' .. pattern) == 1 then
        return test_path
      end
    end
  end
  
  return current_dir
end


local function ensure_knowledge_file()
  local project_root = find_project_root()
  local codecompanion_dir = project_root .. '/.codecompanion'
  local knowledge_file = codecompanion_dir .. '/project-knowledge.md'
  
  -- Create directory if it doesn't exist
  if vim.fn.isdirectory(codecompanion_dir) == 0 then
    vim.fn.mkdir(codecompanion_dir, 'p')
  end
  
  -- Create basic knowledge file structure if it doesn't exist
  -- (LLM will handle initialization via initialize_project_knowledge tool)
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
  local preview = string.format("Description: %s", proposal.description)
  
  if proposal.files and #proposal.files > 0 then
    preview = preview .. string.format("\nFiles: %s", table.concat(proposal.files, ', '))
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
    vim.ui.select(
      {'✓ Approve', '✗ Reject'}, 
      {
        prompt = 'Store this knowledge?\n\n' .. preview,
        format_item = function(item) return item end
      },
      function(choice)
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
      end
    )
  end)
end

-- Load project knowledge for auto-injection into chat context
local function load_project_knowledge()
  local knowledge_file = ensure_knowledge_file()
  
  local file = io.open(knowledge_file, 'r')
  if not file then
    return nil
  end
  
  local content = file:read('*all')
  file:close()
  
  if not content or content == '' then
    return nil
  end
  
  -- Parse and format for system context
  local context = "PROJECT CONTEXT:\n"
  
  -- Extract project overview
  local overview = content:match('## Project Overview\n(.-)##')
  if overview and overview:match('%S') then
    overview = overview:gsub('%*(.-)%*', ''):gsub('\n+', ' '):gsub('^%s*', ''):gsub('%s*$', '')
    if overview ~= '' then
      context = context .. "- " .. overview .. "\n"
    end
  end
  
  -- Extract directory structure
  local directories = content:match('## Directory Structure\n(.-)##')
  if directories and directories:match('%S') then
    directories = directories:gsub('%*(.-)%*', ''):gsub('\n+', ' '):gsub('^%s*', ''):gsub('%s*$', '')
    if directories ~= '' then
      context = context .. "- " .. directories .. "\n"
    end
  end
  
  -- Extract current features
  local features = content:match('## Current Features in Development\n(.-)$')
  if not features then
    features = content:match('## Current Features in Development\n(.-)##')
  end
  if features and features:match('%S') then
    features = features:gsub('%*(.-)%*', ''):gsub('\n+', ' '):gsub('^%s*', ''):gsub('%s*$', '')
    if features ~= '' then
      context = context .. "- Current: " .. features .. "\n"
    end
  end
  
  -- Extract recent changelog entries (last 3)
  local recent_changes = {}
  for entry in content:gmatch('### %d%d%d%d%-%d%d%-%d%d\n%- %*%*(.-)%*%*') do
    table.insert(recent_changes, entry)
    if #recent_changes >= 3 then
      break
    end
  end
  
  if #recent_changes > 0 then
    context = context .. "- Recent: " .. table.concat(recent_changes, ', ') .. "\n"
  end
  
  return context
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
  name = 'update_project_knowledge',
  
  opts = {},
  
  cmds = {
    function(self, args, input, callback)
      -- Only for updating/storing knowledge, not loading
      local proposal = {
        description = args.description,
        files = args.files or get_recent_changed_files()
      }
      
      if not proposal.description or proposal.description == '' then
        callback({
          status = 'error',
          data = 'Error: Description is required'
        })
        return
      end
      
      -- Show user approval dialog
      show_knowledge_approval_dialog(proposal, function(result)
        callback({
          status = 'success',
          data = result
        })
      end)
    end,
  },
  
  schema = {
    ['function'] = {
      description = 'Update project knowledge with new information (project context is auto-loaded at chat start)',
      parameters = {
        type = 'object',
        properties = {
          description = {
            type = 'string',
            description = 'Brief description of what was accomplished or learned'
          },
          files = {
            type = 'array',
            items = { type = 'string' },
            description = 'List of files involved in this change (optional, will auto-detect from git if not provided)'
          }
        },
        required = { 'description' }
      }
    }
  }
}