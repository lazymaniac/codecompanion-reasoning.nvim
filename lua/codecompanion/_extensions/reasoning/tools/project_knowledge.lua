-- Enhanced project knowledge tool with categorized fact system
local FACT_CATEGORIES = {
  architecture = {
    description = 'Code locations and architectural patterns',
    section_title = 'Architecture Facts',
    examples = {
      'Authentication logic is in src/auth/ (JWT + middleware pattern)',
      'Database models are in app/models/ (Sequelize ORM)',
      'API routes are in routes/api/ (Express.js with validation)',
    },
  },
  workflow = {
    description = 'Development commands and processes',
    section_title = 'Workflow Facts',
    examples = {
      'Testing: Run `npm test` (requires Docker running)',
      'Database setup: Run `npm run db:migrate` then `npm run db:seed`',
      'Build process: Uses Webpack with hot reload in dev mode',
    },
  },
  business_logic = {
    description = 'Feature behavior and business rules',
    section_title = 'Business Logic Facts',
    examples = {
      'User permissions: Role-based (admin/user/guest) defined in User.role',
      'Payment processing: Stripe integration in src/payments/ (webhooks + async)',
      'File uploads: Limited to 10MB, stored in S3 with presigned URLs',
    },
  },
  constraints = {
    description = 'Technical limitations and requirements',
    section_title = 'Constraints Facts',
    examples = {
      'Performance constraint: API responses must be <200ms (monitored)',
      'Security requirement: All API endpoints require JWT authentication',
      'Database constraint: MySQL 8.0+ required for JSON column features',
    },
  },
}

local function find_project_root()
  return vim.fn.getcwd()
end

local function get_knowledge_file_path()
  local project_root = find_project_root()
  return project_root .. '/.codecompanion/project-knowledge.md'
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
    local initial_content = [[# PROJECT KNOWLEDGE

## Project Overview
*Capture purpose, tech stack, and how to run/test the project.*

## Directory Structure
*Highlight important directories and their responsibilities.*

## Architecture Facts
*Code locations and architectural patterns*

## Workflow Facts
*Development commands and processes*

## Business Logic Facts
*Feature behavior and business rules*

## Constraints Facts
*Technical limitations and requirements*
]]
    local file = io.open(knowledge_file, 'w')
    if file then
      file:write(initial_content)
      file:close()
    end
  end

  return knowledge_file
end

local function format_knowledge_preview(proposal)
  local category_info = FACT_CATEGORIES[proposal.category]
  local preview = string.format('Category: %s (%s)', proposal.category, category_info.description)
  preview = preview .. string.format('\nFact: %s', proposal.description)

  if proposal.sources and #proposal.sources > 0 then
    preview = preview .. string.format('\nSources: %s', table.concat(proposal.sources, ', '))
  end

  return preview
end

local function ensure_category_section(lines, category)
  local category_info = FACT_CATEGORIES[category]
  if not category_info then
    return nil
  end

  local section_header = '## ' .. category_info.section_title
  local header_index

  for idx, line in ipairs(lines) do
    if line == section_header then
      header_index = idx
      break
    end
  end

  if header_index then
    return header_index
  end

  -- Add section if it doesn't exist
  if #lines > 0 and lines[#lines] ~= '' then
    table.insert(lines, '')
  end
  table.insert(lines, section_header)
  table.insert(lines, '*' .. category_info.description .. '*')
  table.insert(lines, '')

  return #lines - 2 -- Return header index
end

local function store_categorized_fact(knowledge_file, category, description, sources)
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

  local header_index = ensure_category_section(lines, category)
  if not header_index then
    return false
  end

  -- Remove placeholder if it exists
  local category_info = FACT_CATEGORIES[category]
  local placeholder_line = '*' .. category_info.description .. '*'
  if lines[header_index + 1] == placeholder_line then
    table.remove(lines, header_index + 1)
    if lines[header_index + 1] == '' then
      table.remove(lines, header_index + 1)
    end
  end

  -- Find insertion point
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

  -- Ensure proper spacing
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
        local success =
          store_categorized_fact(knowledge_file, proposal.category, proposal.description, proposal.sources)

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
        category = args.category,
        description = args.description,
        sources = args.sources,
      }

      if not proposal.category or proposal.category == '' then
        callback({
          status = 'error',
          data = 'Error: Category is required',
        })
        return
      end

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
      description = [[Record durable project facts that reduce future discovery time. 
CAPTURE: Location of features, workflow commands, business rules, technical constraints
AVOID: Temporary findings, opinions, implementation details that change frequently

EXAMPLES:
• "Authentication logic is in src/auth/ (JWT + middleware pattern)" 
• "Testing: Run `npm test` (requires Docker running)"
• "User permissions: Role-based (admin/user/guest) defined in User.role"
• "Performance constraint: API responses must be <200ms (monitored)"

Facts auto-load in future chats to reduce token usage and discovery time.]],
      parameters = {
        type = 'object',
        properties = {
          category = {
            type = 'string',
            enum = { 'architecture', 'workflow', 'business_logic', 'constraints' },
            description = 'Type of knowledge being captured',
          },
          description = {
            type = 'string',
            description = 'Concise fact that will be valuable in future sessions. Focus on "where", "how", or "what" rather than "why"',
          },
          sources = {
            type = 'array',
            items = { type = 'string' },
            description = 'Files, commands, or documentation that validate this fact',
          },
        },
        required = { 'category', 'description' },
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
