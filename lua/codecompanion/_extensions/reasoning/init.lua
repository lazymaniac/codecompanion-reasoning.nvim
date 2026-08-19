local Config = require('codecompanion._extensions.reasoning.config')
local Constants = require('codecompanion._extensions.reasoning.constants')
local Schema = require('codecompanion._extensions.reasoning.schema')
local resolve_schema = Schema.resolve

local M = {}
local owned_default_tools = setmetatable({}, { __mode = 'k' })
local owned_callbacks = setmetatable({}, { __mode = 'k' })

local paths = {}
for _, name in ipairs(Constants.tool_names) do
  paths[name] = '_extensions.reasoning.tools.' .. name:gsub('^reasoning_', '')
end

local descriptions = {
  reasoning_start = 'Frame the problem and open the reasoning workspace',
  reasoning_amend = 'Add newly discovered work to the active frame',
  reasoning_revise = 'Restate the frame and retire downstream work',
  reasoning_replace = 'Discard the workspace and reframe from scratch',
  reasoning_split = 'Split a problem into atomic sub-questions',
  reasoning_answer = 'Close a sub-question with cited evidence',
  reasoning_drop = 'Close a sub-question that needs no answer',
  reasoning_evidence = 'Record sourced and falsifiable evidence or assumptions',
  reasoning_options = 'Create competing solutions, hypotheses, or scenarios',
  reasoning_options_replace = 'Replace a branch set with corrected alternatives',
  reasoning_review = 'Adversarially challenge and revise reasoning artifacts',
  reasoning_resolve_contradiction = 'Reconcile two contradictory artifacts',
  reasoning_checkpoint = 'Record progress without claiming completion',
  reasoning_final = 'Publish the gated final answer',
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

PROCESS. Each tool performs one action and takes only the fields that action needs. Every accepted result returns next_action.tool: that is the protocol state, so call it next.
1. reasoning_start frames the problem: objective, constraints, success criteria, unknowns, perspectives. Use %s depth unless the problem warrants another explicit depth. Each unknown becomes a provisional sub-question.
2. reasoning_split decomposes the frame, and later any leaf that hides several questions, into atomic sub-questions. A sub-question is atomic when one stated observation closes it. Split the problem with reasoning_split before gathering evidence.
3. reasoning_evidence records sourced, falsifiable observations, claims, and labelled assumptions for the open leaf, the uncovered perspective, or the unresolved unknown that next_action names.
4. Every leaf must be closed by reasoning_answer with cited active evidence, or by reasoning_drop with a classified justification. A closure holds only while its evidence stays active.
5. reasoning_options develops two to six genuinely competing solutions, hypotheses, or scenarios when the frame requires branching. Do not select an option in the call that invents it.
6. reasoning_review defends the strongest case, attacks it, exposes hidden assumptions and blind spots, and records keep, revise, or retract verdicts. A deep frame needs a full review; a temporal frame needs stress tests.
7. reasoning_final publishes the answer once every gate passes.

MID-RUN TOOLS. Work discovered mid-run uses reasoning_amend, which adds unknowns, criteria, constraints, and perspectives while keeping every artifact. reasoning_revise restates a wrong frame and retires downstream work; reasoning_replace discards the workspace. reasoning_options_replace corrects a branch set as one unit. reasoning_resolve_contradiction reconciles two conflicting artifacts under an explicit, supported qualification. reasoning_checkpoint records progress and previews the remaining gates without publishing anything.

GATES. reasoning_final is rejected until: every leaf is closed and every closure still supported; evidence covers each framed perspective and each framed unknown; competing branches exist with an active selected option when the frame requires branching, each option citing active evidence and stating a prediction; a relevant review exists, full for a deep frame and stress-tested for a temporal frame; no contradiction or required revision is outstanding; and every success criterion has one supported passed or explained not_applicable result. A rejected final reports its unmet gates and changes nothing.

RULES.
1. Attaching the complete reasoning group commits this conversation to the structured final-answer path.
2. External project tools are unrestricted and budget-neutral. Between reasoning calls, search, read files, inspect symbols and history, run commands and tests, and call other non-reasoning tools as needed; those calls do not advance protocol state.
3. The first reasoning call must be reasoning_start.
4. Call exactly one reasoning tool at a time; never batch reasoning calls. Satisfy next_action.reason before the next reasoning call.
5. Any tool that shares the named tool's role is accepted, so a leaf may be dropped where an answer was suggested, a branch set replaced instead of created, or a checkpoint recorded where a final is ready.
6. Never write the final answer directly as model prose; only reasoning_final may publish it.
7. A rejected call is retryable and returns committed=false. Correct the reported diagnostic path and retry. Never repeat unchanged rejected arguments.
8. Rejected artifact IDs do not exist and must never be cited or reused.
9. New user information requires reasoning_revise before downstream reasoning continues, or reasoning_replace when the existing work is unusable.
10. The deterministic final answer may use only accepted artifacts and their validated references.
11. Read open_items on every result: it lists the open leaves in order, unsupported closures, open revisions, and unresolved contradictions.
12. If next_action.tool is none, stop; no further model action is permitted and never call a tool named none.

Keep artifacts concise and externally inspectable. Never record or reveal private chain-of-thought. The tools validate structure, references, ordering, and coverage. They do not establish factual truth, guarantee independent perspectives, or replace external verification.
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
