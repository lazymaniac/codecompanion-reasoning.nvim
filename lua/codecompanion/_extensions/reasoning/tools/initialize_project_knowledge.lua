local function find_project_root()
  local root_patterns = { '.git', 'package.json', 'Cargo.toml', 'pyproject.toml', 'go.mod', '.project' }

  local current_dir = vim.fn.getcwd()
  local path_parts = vim.split(current_dir, '/')

  for i = #path_parts, 1, -1 do
    local test_path = '/' .. table.concat(path_parts, '/', 1, i)

    for _, pattern in ipairs(root_patterns) do
      if
        vim.fn.filereadable(test_path .. '/' .. pattern) == 1 or vim.fn.isdirectory(test_path .. '/' .. pattern) == 1
      then
        return test_path
      end
    end
  end

  return current_dir
end

local function check_ai_context_files()
  local project_root = find_project_root()
  local context_files = {
    'CLAUDE.md',
    '.claude.md',
    'AGENTS.md',
    'agents.md',
    '.agents.md',
    '.cursorrules',
    'cursor.md',
    '.github/copilot-instructions.md',
    'copilot-instructions.md',
    'AI_CONTEXT.md',
    'ai-context.md',
    'INSTRUCTIONS.md',
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
    vim.ui.select({ '✓ Initialize', '✗ Cancel' }, {
      prompt = 'No project knowledge file found. Initialize by analyzing project structure?',
      format_item = function(item)
        return item
      end,
    }, function(choice)
      if choice == '✓ Initialize' then
        callback('✓ Starting project knowledge initialization...')
      else
        callback('✗ Project knowledge initialization cancelled')
      end
    end)
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
          data = '✓ Project knowledge file already exists. Use update_project_knowledge to modify it.',
        })
        return
      end

      -- Prompt user to initialize when missing
      local ai_files = check_ai_context_files()

      show_initialization_prompt(function(result)
        if not result:match('✓') then
          callback({ status = 'success', data = result })
          return
        end

        -- Ensure directory exists
        local project_root = find_project_root()
        local codecompanion_dir = project_root .. '/.codecompanion'
        if vim.fn.isdirectory(codecompanion_dir) == 0 then
          vim.fn.mkdir(codecompanion_dir, 'p')
        end

        -- Try to attach add_tools tool to current chat for the model to use
        local chat = self and self.chat or nil
        if not chat then
          -- Best-effort fallback to locate chat from current buffer
          local ok, Chat = pcall(require, 'codecompanion.strategies.chat')
          if ok and Chat.buf_get_chat then
            local buf = vim.api.nvim_get_current_buf()
            local okc, found = pcall(Chat.buf_get_chat, buf)
            if okc then
              chat = found
            end
          end
        end

        -- Add add_tools and update_project_knowledge tools into chat so LLM can act
        local added_tools = false
        local config_ok, config = pcall(require, 'codecompanion.config')
        if
          chat
          and config_ok
          and config
          and config.strategies
          and config.strategies.chat
          and config.strategies.chat.tools
        then
          local add_cfg = config.strategies.chat.tools['add_tools']
          local update_cfg = config.strategies.chat.tools['update_project_knowledge']
          if chat.tool_registry and chat.tool_registry.add then
            if add_cfg then
              pcall(function()
                chat.tool_registry:add('add_tools', add_cfg, { visible = true })
              end)
              added_tools = true
            end
            if update_cfg then
              pcall(function()
                chat.tool_registry:add('update_project_knowledge', update_cfg, { visible = true })
              end)
              added_tools = true
            end
          end
        end

        -- Build an instruction message for the LLM
        local knowledge_path = project_root .. '/.codecompanion/project-knowledge.md'
        local header = 'Initialize Project Knowledge'
        local lines = {
          header,
          '',
          'Goal: Create or extract a comprehensive project knowledge file at `' .. knowledge_path .. '`.',
          '',
          'Steps:',
          '- First, call `add_tools` with `action="list_tools"`, then `add_tool` to add tools that can read files and write/edit files (e.g., a read file tool and an insert/edit file tool).',
        }

        if #ai_files > 0 then
          table.insert(
            lines,
            '- Read these AI context files if available: '
              .. table.concat(ai_files, ', ')
              .. ' and extract the relevant project knowledge.'
          )
        else
          table.insert(
            lines,
            '- If no AI context files are present, discover project details from files like `README.md`, `package.json`, configuration files, and directory structure.'
          )
        end

        table.insert(
          lines,
          '- Use the template in `.codecompanion/project-knowledge.md` if it already exists; otherwise, create it with the following structure:'
        )
        table.insert(lines, '  - Project Overview: what the project does, tech stack, how to run/test')
        table.insert(lines, '  - Directory Structure: key directories and their purposes')
        table.insert(lines, '  - Changelog: start empty')
        table.insert(lines, '  - Current Features in Development: start empty')
        table.insert(lines, '')
        table.insert(lines, 'Important: After creation, future project context should load only from this file.')

        local message = table.concat(lines, '\n')

        -- Queue the instruction into the current chat for immediate model response
        if chat and chat.add_message then
          pcall(function()
            chat:add_message({ role = 'user', content = message }, { visible = true })
            if chat.add_tool_output then
              chat:add_tool_output(
                self,
                'Queued project knowledge initialization instructions in chat.',
                'Queued project knowledge initialization instructions in chat.'
              )
            end
          end)
        end

        callback({
          status = 'success',
          data = (added_tools and '✓ Added tools and queued LLM instructions' or '✓ Queued LLM instructions')
            .. (#ai_files > 0 and (' (will extract from: ' .. table.concat(ai_files, ', ') .. ')') or ''),
        })
      end)
    end,
  },

  schema = {
    ['function'] = {
      description = 'Initialize project knowledge: prompt user, add add_tools to chat, and instruct LLM to extract from CLAUDE.md/AGENTS.md or create new file.',
      parameters = {
        type = 'object',
        properties = {},
        required = {},
      },
    },
  },
}
