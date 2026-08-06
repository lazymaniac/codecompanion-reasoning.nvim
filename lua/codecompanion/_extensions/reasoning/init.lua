local Config = require('codecompanion._extensions.reasoning.config')
local Constants = require('codecompanion._extensions.reasoning.constants')
local Schema = require('codecompanion._extensions.reasoning.schema')
local resolve_schema = Schema.resolve

local M = {}
local owned_default_tools = setmetatable({}, { __mode = 'k' })
local owned_callbacks = setmetatable({}, { __mode = 'k' })

local paths = {
  reasoning_frame = '_extensions.reasoning.tools.frame',
  reasoning_evidence = '_extensions.reasoning.tools.evidence',
  reasoning_options = '_extensions.reasoning.tools.options',
  reasoning_review = '_extensions.reasoning.tools.review',
  reasoning_synthesis = '_extensions.reasoning.tools.synthesis',
}

local descriptions = {
  reasoning_frame = 'Frame a difficult problem before developing conclusions',
  reasoning_evidence = 'Record sourced and falsifiable evidence or assumptions',
  reasoning_options = 'Create competing solutions, hypotheses, or scenarios',
  reasoning_review = 'Adversarially challenge and revise reasoning artifacts',
  reasoning_synthesis = 'Record a checkpoint or gated final synthesis',
}

local function tool_callback(name)
  local template = vim.deepcopy(require('codecompanion.' .. paths[name]))
  local callback = function()
    return resolve_schema(name, template)
  end
  owned_callbacks[callback] = {
    name = name,
    command = template.cmds and template.cmds[1] or nil,
  }
  return callback
end

function M.owns_tool_config(name, config)
  if type(config) ~= 'table' or getmetatable(config) ~= nil then
    return false
  end
  local ownership = owned_callbacks[rawget(config, 'callback')]
  if not ownership or ownership.name ~= name or type(ownership.command) ~= 'function' then
    return false
  end
  for _, field in ipairs({ 'extends', 'path', '_adapter_tool', '_has_client_tool' }) do
    if rawget(config, field) ~= nil then
      return false
    end
  end
  local opts = rawget(config, 'opts')
  if opts ~= nil and (type(opts) ~= 'table' or getmetatable(opts) ~= nil or rawget(opts, 'client_tool') ~= nil) then
    return false
  end
  return vim.deep_equal(opts, ownership.opts)
end

local function tool_registration(name, existing)
  local registration = {
    callback = tool_callback(name),
    description = descriptions[name],
  }
  if type(existing) == 'table' then
    if type(existing.description) == 'string' then
      registration.description = existing.description
    end
    if type(existing.visible) == 'boolean' then
      registration.visible = existing.visible
    end
    if type(existing.opts) == 'table' then
      local approval_options = {}
      for _, key in ipairs({ 'require_approval_before', 'allowed_in_yolo_mode', 'judge_in_yolo_mode' }) do
        if existing.opts[key] ~= nil then
          approval_options[key] = vim.deepcopy(existing.opts[key])
        end
      end
      if next(approval_options) then
        registration.opts = approval_options
      end
    end
  end
  owned_callbacks[registration.callback].opts = vim.deepcopy(registration.opts)
  return registration
end

local function group_registration(system_prompt, existing)
  local group = {
    description = 'Guided reasoning for difficult analysis, diagnosis, design, decision, and planning problems',
    system_prompt = system_prompt,
    tools = vim.deepcopy(Constants.tool_names),
    opts = { collapse_tools = true },
  }
  if type(existing) ~= 'table' then
    return group
  end
  if type(existing.description) == 'string' then
    group.description = existing.description
  end
  if type(existing.opts) == 'table' and type(existing.opts.collapse_tools) == 'boolean' then
    group.opts.collapse_tools = existing.opts.collapse_tools
  end
  return group
end

function M.setup(user_options)
  local options = Config.setup(user_options)
  require('codecompanion._extensions.reasoning.control').setup_autocmds()
  local tools = require('codecompanion.config').interactions.chat.tools
  tools.groups = tools.groups or {}
  tools.opts = tools.opts or {}
  tools.opts.default_tools = tools.opts.default_tools or {}
  for _, name in ipairs(Constants.tool_names) do
    tools[name] = tool_registration(name, tools[name])
  end
  local system_prompt = string.format(
    [[<structured_reasoning>
Use this protocol for difficult problems. Routine requests do not need the group.
Runtime rules:
1. Attaching the complete reasoning group commits this conversation to the structured final-answer path.
2. External project tools are unrestricted and budget-neutral. Between reasoning calls, search, read files, inspect symbols and history, run commands and tests, and call other non-reasoning tools as needed; those calls do not advance protocol state.
3. The first reasoning call must be reasoning_frame with action=start. Use %s depth unless the problem warrants another explicit depth.
4. Never write the final answer directly as model prose; only the deterministic completion path may publish it.
5. A rejected call is retryable and returns committed=false. Correct the reported field and retry the authoritative next_action.tool.
6. Rejected artifact IDs do not exist and must never be cited or reused.
7. New user information requires reasoning_frame with action=revise or action=replace before downstream reasoning continues.
8. The deterministic final answer may use only accepted artifacts and their validated references.
Treat each accepted result's next_action.tool as the protocol state transition. Call exactly one reasoning tool at a time; never batch reasoning calls. Satisfy next_action.reason before making the next reasoning call. Never repeat unchanged rejected arguments.
Record decision-relevant observations, claims, and labelled assumptions with reasoning_evidence. Every item needs a concrete source and an observable result that would falsify or materially revise it. Link evidence to exact framed unknowns when it addresses them.
For decisions, diagnoses, designs, and plans, use reasoning_options to maintain genuinely competing solutions, hypotheses, or scenarios. Do not select an option in the same call that invents it.
Use reasoning_review to defend the strongest case, attack it, expose hidden assumptions and blind spots, and record corrections. Use temporal stress tests when the frame requires reasoning across transitions. Resolve contradictions only with an explicit, supported qualification record.
A submitted final synthesis must clear every structural gate. Checkpoint mode is optional; use it when a compact progress record or gate preview would help. If next_action.tool is none, stop; no further model action is permitted and never call a tool named none.
Keep artifacts concise and externally inspectable. Never record or reveal private chain-of-thought.
The tools validate structure, references, ordering, and coverage. They do not establish factual truth, guarantee independent perspectives, or replace external verification.
</structured_reasoning>]],
    options.default_depth
  )
  tools.groups.reasoning = group_registration(system_prompt, tools.groups.reasoning)

  local default_tools = tools.opts.default_tools
  if options.auto_attach then
    if not vim.tbl_contains(default_tools, 'reasoning') then
      table.insert(default_tools, 'reasoning')
      owned_default_tools[default_tools] = true
    end
  elseif owned_default_tools[default_tools] then
    for index = #default_tools, 1, -1 do
      if default_tools[index] == 'reasoning' then
        table.remove(default_tools, index)
        break
      end
    end
    owned_default_tools[default_tools] = nil
  end
end

M.exports = {
  tool_names = function()
    return vim.deepcopy(Constants.tool_names)
  end,
}

return M
