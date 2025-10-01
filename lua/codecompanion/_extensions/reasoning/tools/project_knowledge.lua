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
*Capture purpose, tech stack, and how to run/test the project.*

## Directory Structure
*Highlight important directories and their responsibilities.*

## Key Facts
*Use `project_knowledge` to capture durable insights (e.g., auth lives in `apps/auth`).*
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

local function format_knowledge_preview(proposal)
  local preview = string.format('Description: %s', proposal.description)

  if proposal.sources and #proposal.sources > 0 then
    preview = preview .. string.format('\nSources: %s', table.concat(proposal.sources, ', '))
  end

  return preview
end

local function ensure_key_facts_section(lines)
  local header_index
  for idx, line in ipairs(lines) do
    if line == '## Key Facts' then
      header_index = idx
      break
    end
  end

  if header_index then
    return header_index
  end

  if #lines > 0 and lines[#lines] ~= '' then
    table.insert(lines, '')
  end
  table.insert(lines, '## Key Facts')
  table.insert(lines, '*Use `project_knowledge` to capture durable insights (e.g., auth lives in `apps/auth`).*')

  return #lines - 1
end

local function store_fact_entry(knowledge_file, description, sources)
  local entry = string.format('- %s', description)

  if sources and #sources > 0 then
    entry = entry .. string.format(' (sources: %s)', table.concat(sources, ', '))
  end

  local file = io.open(knowledge_file, 'r')
  if not file then
    return false
  end

  local content = file:read('*all') or ''
  file:close()

  local lines = vim.split(content, '\n', { plain = true, trimempty = false })

  local header_index = ensure_key_facts_section(lines)

  local placeholder_line = '*Use `project_knowledge` to capture durable insights (e.g., auth lives in `apps/auth`).*'
  if lines[header_index + 1] == placeholder_line then
    table.remove(lines, header_index + 1)
  end

  local insert_index = header_index + 1
  while insert_index <= #lines do
    local line = lines[insert_index]
    if line == '' then
      local next_line = lines[insert_index + 1]
      if not next_line or next_line:match('^##%s') then
        break
      end
    elseif line:match('^##%s') then
      break
    end
    insert_index = insert_index + 1
  end

  table.insert(lines, insert_index, entry)

  local next_line = lines[insert_index + 1]
  if next_line and next_line ~= '' and next_line:match('^##%s') then
    table.insert(lines, insert_index + 1, '')
  end

  local updated_content = table.concat(lines, '\n')
  if not updated_content:match('\n$') then
    updated_content = updated_content .. '\n'
  end

  file = io.open(knowledge_file, 'w')
  if not file then
    return false
  end
  file:write(updated_content)
  file:close()

  return true
end

local function show_knowledge_approval_dialog(proposal, callback)
  local preview = format_knowledge_preview(proposal)

  vim.schedule(function()
    vim.ui.select({ '✓ Approve', '✗ Reject' }, {
      prompt = 'Store this project fact?\n\n' .. preview,
      format_item = function(item)
        return item
      end,
    }, function(choice)
      if choice == '✓ Approve' then
        local knowledge_file = ensure_knowledge_file()
        local success = store_fact_entry(knowledge_file, proposal.description, proposal.sources)

        if success then
          callback('✓ Fact stored: ' .. proposal.description)
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
  if vim.fn.filereadable(knowledge_file) == 0 then
    return nil
  end

  local file = io.open(knowledge_file, 'r')
  if not file then
    return nil
  end
  local content = file:read('*all')
  file:close()

  if not content or content == '' then
    return nil
  end
  return content
end

_G.CodeCompanionProjectKnowledge = {
  load_project_knowledge = load_project_knowledge,
  auto_load_project_context = load_project_knowledge,
}

return {
  name = 'project_knowledge',

  opts = {},

  cmds = {
    function(self, args, input, callback)
      local proposal = {
        description = args.description,
        sources = args.sources,
      }

      if not proposal.description or proposal.description == '' then
        callback({
          status = 'error',
          data = 'Error: Description is required',
        })
        return
      end

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
      description = 'Record durable project knowledge (context auto-loaded at chat start).',
      parameters = {
        type = 'object',
        properties = {
          description = {
            type = 'string',
            description = 'Brief description of what was accomplished or learned',
          },
          sources = {
            type = 'array',
            items = { type = 'string' },
            description = 'List key sources (files, docs, URLs) backing the fact (optional).',
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
