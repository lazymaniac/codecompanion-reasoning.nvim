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

local function check_ai_context_files()
  local project_root = find_project_root()
  local context_files = {
    'CLAUDE.md', '.claude.md', '.cursorrules', 'cursor.md',
    '.github/copilot-instructions.md', 'copilot-instructions.md',
    'AI_CONTEXT.md', 'ai-context.md', 'INSTRUCTIONS.md'
  }
  
  local found_files = {}
  for _, file in ipairs(context_files) do
    local file_path = project_root .. '/' .. file
    if vim.fn.filereadable(file_path) == 1 then
      table.insert(found_files, file)
    end
  end
  
  return found_files
end

local function project_knowledge_exists()
  local project_root = find_project_root()
  local knowledge_file = project_root .. '/.codecompanion/project-knowledge.md'
  return vim.fn.filereadable(knowledge_file) == 1
end

local function show_initialization_prompt(callback)
  vim.schedule(function()
    vim.ui.select(
      {'✓ Initialize', '✗ Cancel'}, 
      {
        prompt = 'No project knowledge file found. Initialize by analyzing project structure?',
        format_item = function(item) return item end
      },
      function(choice)
        if choice == '✓ Initialize' then
          callback('✓ Starting project knowledge initialization...')
        else
          callback('✗ Project knowledge initialization cancelled')
        end
      end
    )
  end)
end

return {
  name = 'initialize_project_knowledge',
  
  opts = {},
  
  cmds = {
    function(self, args, input, callback)
      -- Check if project knowledge already exists
      if project_knowledge_exists() then
        callback({
          status = 'success',
          data = '✓ Project knowledge file already exists. Use update_project_knowledge to modify it.'
        })
        return
      end
      
      -- Check if we have existing AI context files
      local ai_files = check_ai_context_files()
      if #ai_files > 0 then
        callback({
          status = 'success',
          data = string.format('✓ Found existing AI context files: %s. Project intelligence will auto-load from these.', 
                              table.concat(ai_files, ', '))
        })
        return
      end
      
      -- No project knowledge and no AI context files - prompt for initialization
      show_initialization_prompt(function(result)
        if result:match('✓') then
          -- Create the .codecompanion directory
          local project_root = find_project_root()
          local codecompanion_dir = project_root .. '/.codecompanion'
          if vim.fn.isdirectory(codecompanion_dir) == 0 then
            vim.fn.mkdir(codecompanion_dir, 'p')
          end
          
          -- Return a message that triggers LLM to analyze the project
          callback({
            status = 'success',
            data = [[✓ Project intelligence initialization started. 

NEXT STEPS FOR YOU:
1. Use add_tools to get access to Read, LS, and Grep tools
2. Read existing AI context files (CLAUDE.md, .cursorrules, etc.) if they exist to extract project information
3. Analyze the project structure by reading key files (package.json, README.md, etc.)
4. Explore the directory structure to understand the codebase organization  
5. Write a comprehensive project knowledge file at .codecompanion/project-knowledge.md with:
   - Project Overview (what the project does, tech stack, how to run/test)
   - Directory Structure (key directories and their purposes)
   - Current Features in Development (leave empty initially)
   - Changelog (leave empty initially)

IMPORTANT: After creating this file, all future project context will load ONLY from .codecompanion/project-knowledge.md, not from CLAUDE.md or other AI files.

Please start by adding the necessary tools and then analyzing the project.]]
          })
        else
          callback({
            status = 'success',
            data = result
          })
        end
      end)
    end,
  },
  
  schema = {
    ['function'] = {
      description = 'Initialize project knowledge file by analyzing project structure (only if no AI context files exist)',
      parameters = {
        type = 'object',
        properties = {},
        required = {}
      }
    }
  }
}