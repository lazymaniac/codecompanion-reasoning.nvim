local tool_filter_ok, ToolFilter = pcall(require, 'codecompanion.strategies.chat.tools.tool_filter')
if not tool_filter_ok then
  ToolFilter = {
    filter = function()
      return {}
    end,
    filter_enabled_tools = function()
      return {}
    end,
  }
end

local tools_ok, Tools = pcall(require, 'codecompanion.strategies.chat.tools.init')
if not tools_ok then
  Tools = {
    get_tools = function()
      return {}
    end,
    resolve = function()
      return { schema = {}, handlers = {}, output = {} }
    end,
  }
end

local config_ok, config = pcall(require, 'codecompanion.config')
if not config_ok then
  config = { strategies = { chat = { tools = {} } } }
end

local fmt = string.format

local ToolCatalog = {}

ToolCatalog.excluded_tools = {
  ['chain_of_thoughts_agent'] = true,
  ['tree_of_thoughts_agent'] = true,
  ['graph_of_thoughts_agent'] = true,
  ['meta_agent'] = true,
  ['ask_user'] = true,
  ['add_tools'] = true,
  ['project_knowledge'] = true,
  ['initialize_project_knowledge'] = true,
}

local function extract_first_sentence(description)
  if not description or description == '' then
    return 'No description provided'
  end

  local first_sentence = description:match('^[^%.%!%?]*[%.%!%?]')

  if first_sentence then
    return first_sentence:gsub('^%s*(.-)%s*$', '%1')
  else
    if #description <= 80 then
      return description
    else
      return description:sub(1, 77) .. '...'
    end
  end
end

local function get_tools_config()
  local strategies = config.strategies or {}
  local chat = strategies.chat or {}
  return chat.tools or {}
end

local function compute_enabled_lookup(tools_config)
  if ToolFilter and ToolFilter.filter_enabled_tools then
    local ok, enabled = pcall(ToolFilter.filter_enabled_tools, tools_config)
    if ok and type(enabled) == 'table' then
      if next(enabled) == nil then
        return nil
      end
      return enabled
    end
  end
  return nil
end

local function is_tool_enabled(name, enabled_lookup)
  if not enabled_lookup then
    return true
  end
  return enabled_lookup[name] or false
end

---Get all tools with their complete configuration and resolved details
---@return table<string, table>
function ToolCatalog.get_tool_catalog()
  local tools_config = get_tools_config()
  local enabled_lookup = compute_enabled_lookup(tools_config)
  local result = {}

  for tool_name, tool_config in pairs(tools_config) do
    if tool_name ~= 'opts' and tool_name ~= 'groups' and not ToolCatalog.excluded_tools[tool_name] then
      local is_enabled = is_tool_enabled(tool_name, enabled_lookup)

      local tool_info = {
        name = tool_name,
        enabled = is_enabled,
        config = vim.deepcopy(tool_config),
        description = tool_config.description or 'No description provided',
        callback = tool_config.callback,
        opts = tool_config.opts or {},
        resolved = nil,
        schema = nil,
        error = nil,
      }

      if is_enabled and tool_config.callback then
        local ok, resolved_tool = pcall(function()
          return Tools.resolve(tool_config)
        end)

        if ok and resolved_tool then
          tool_info.resolved = true
          tool_info.schema = resolved_tool.schema

          if resolved_tool.handlers then
            tool_info.has_handlers = true
            tool_info.handler_types = vim.tbl_keys(resolved_tool.handlers)
          end

          if resolved_tool.output then
            tool_info.has_output_handlers = true
            tool_info.output_handlers = vim.tbl_keys(resolved_tool.output)
          end
        else
          tool_info.resolved = false
          tool_info.error = 'Failed to resolve tool'
        end
      else
        tool_info.resolved = false
        if not is_enabled then
          tool_info.error = 'Tool is disabled'
        else
          tool_info.error = 'No callback defined'
        end
      end

      result[tool_name] = tool_info
    end
  end

  return result
end

---Return a sorted list of addable tools with lightweight metadata
---@return table[]
function ToolCatalog.get_addable_tools()
  local catalog = ToolCatalog.get_tool_catalog()
  local addable = {}

  for name, info in pairs(catalog) do
    if info.enabled then
      table.insert(addable, {
        name = name,
        description = info.description,
      })
    end
  end

  table.sort(addable, function(a, b)
    return a.name < b.name
  end)

  return addable
end

---Build a Markdown formatted list of available tools for display in system prompt
---@return string|nil
function ToolCatalog.build_available_tools_markdown()
  local tools = ToolCatalog.get_addable_tools()

  if #tools == 0 then
    return nil
  end

  local lines = {
    fmt('Optional tools (%d):', #tools),
    '',
  }

  for _, tool in ipairs(tools) do
    local trimmed_description = extract_first_sentence(tool.description)
    table.insert(lines, fmt('- %s: %s', tool.name, trimmed_description))
  end

  return table.concat(lines, '\n')
end

return ToolCatalog
