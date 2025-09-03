return {
  name = 'initialize_project_knowledge',

  opts = {},

  cmds = {
    --- Write/overwrite `.codecompanion/project-knowledge.md` with provided markdown content.
    ---@param self CodeCompanion.Tools.Tool
    ---@param args { content: string } The full markdown content to store.
    ---@param input any
    function(self, args, input)
      local content = args and args.content

      if not content or content == '' then
        return {
          status = 'error',
          data = 'Provide full knowledge content via parameter "content" (markdown text).',
        }
      end

      local project_root = vim.fn.getcwd()
      local codecompanion_dir = project_root .. '/.codecompanion'

      if vim.fn.isdirectory(codecompanion_dir) == 0 then
        vim.fn.mkdir(codecompanion_dir, 'p')
      end

      local knowledge_path = codecompanion_dir .. '/project-knowledge.md'

      local ok, err = pcall(function()
        local f = assert(io.open(knowledge_path, 'w'))
        f:write(content)
        f:close()
      end)

      if not ok then
        return { status = 'error', data = 'Failed to write project knowledge: ' .. tostring(err) }
      end

      return {
        status = 'success',
        data = 'Project knowledge saved at ' .. knowledge_path,
      }
    end,
  },

  schema = {
    type = 'function',
    ['function'] = {
      name = 'initialize_project_knowledge',
      description = [[
        Create or reinitialize the project knowledge file used by CodeCompanion.
        Example content:
        ```markdown
        # Project Overview
        This project implements a Neovim plugin for advanced AI reasoning.
        ## Architecture
        - Lua modules under `lua/`
        - Tests under `tests/`
        ```
      ]],
      parameters = {
        type = 'object',
        properties = {
          content = {
            type = 'string',
            description = 'Full markdown content to save to `.codecompanion/project-knowledge.md`.',
          },
        },
        required = { 'content' },
        additionalProperties = false,
      },
      strict = true,
    },
  },

  output = {
    success = function(self, agent, cmd, stdout)
      local chat = agent.chat
      local result = vim.iter(stdout):flatten():join('\n')
      chat:add_tool_output(self, result, result)

      -- Auto-submit to continue the conversation flow after file creation
      if chat and type(chat.submit) == 'function' then
        vim.schedule(function()
          pcall(function()
            chat:submit()
          end)
        end)
      end
    end,
    error = function(self, agent, cmd, stderr)
      local chat = agent.chat
      local errors = vim.iter(stderr):flatten():join('\n')
      return chat:add_tool_output(self, errors)
    end,
  },
}
