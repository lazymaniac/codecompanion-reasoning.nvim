---@class CodeCompanion.Agent.UnifiedReasoningPrompt
---Streamlined system prompt generator for reasoning agents
local UnifiedReasoningPrompt = {}

local fmt = string.format

---Generate optimized prompt for reasoning agent
---@param reasoning_type string Type: 'chain', 'tree', or 'graph'
---@param include_context? boolean Whether to include project context (default: true)
---@return string Complete system prompt
function UnifiedReasoningPrompt.generate_for_reasoning(reasoning_type, include_context)
  local configs = {
    chain = {
      role = 'Incremental coding problem solver',
      approach = 'micro-step progression with careful analysis',
      strengths = 'small focused changes, continuous validation, user collaboration',
      workflow = 'Take ONE small action → Analyze result → Ask user if needed → Next micro-step → REPEAT',
    },
    tree = {
      role = 'Multi-path incremental explorer',
      approach = 'exploring alternatives through small experiments',
      strengths = 'testing multiple approaches, comparing small changes, iterative refinement',
      workflow = 'Try small approach → Evaluate outcome → Compare with alternatives → Refine → Next experiment',
    },
    graph = {
      role = 'System evolution manager',
      approach = 'incremental system building with interconnected changes',
      strengths = 'building systems step-by-step, managing dependencies, evolving architecture',
      workflow = 'Add one component → Test connections → Validate dependencies → Evolve gradually',
    },
  }

  local config = configs[reasoning_type]
  if not config then
    error('Invalid reasoning type: ' .. tostring(reasoning_type))
  end

  -- Get project context if requested (default: true)
  include_context = include_context ~= false
  local context_section = ''

  if include_context then
    local MemoryEngine = require('codecompanion._extensions.reasoning.helpers.memory_engine')
    local available, error = MemoryEngine.check_availability()

    if available then
      local enhanced_context = MemoryEngine.get_enhanced_context()
      if enhanced_context then
        context_section = '\n\n' .. enhanced_context .. '\n'
      end
    end
  end

  return fmt(
    [[# ROLE
You are a %s specializing in %s.

# APPROACH
%s for optimal coding solutions.

# CORE STRENGTHS
%s

# MANDATORY WORKFLOW
%s

# MANDATORY WORKFLOW FOR OPEN-SOURCE MODELS
You MUST follow this exact sequence after initialization:

STEP 1: Call add_step/add_thought with your FIRST micro-action
STEP 2: Call add_step/add_thought with your SECOND micro-action
STEP 3: Call add_step/add_thought with your THIRD micro-action
...continue until problem is solved

CRITICAL: You must make MULTIPLE calls to add_step/add_thought - do NOT stop after just one!

MICRO-STEP EXAMPLES (each is a separate add_step/add_thought call):
- "Find file containing authentication logic"
- "Read lines 45-60 to understand current function structure"
- "Identify the specific bug in error handling"
- "Refactor just the validateUser() function"
- "Test the single function change"
- "Ask user about preferred error message format"

WORKFLOW RULES:
1. After initialization → immediately call add_step/add_thought
2. After each step result → call add_step/add_thought again
3. Continue until you have completely solved the problem
4. NEVER stop after one step - keep building the reasoning chain

# TOOL USAGE FOR INCREMENTAL WORK
- Use `add_tools` to find file editing tools for each small change
- Use `ask_user` when facing choices: "Should I refactor this function or create a new one?"
- Make small file edits, not large rewrites
- Read files in sections, don't try to understand everything at once

# COLLABORATION APPROACH
- Ask user for guidance on approach alternatives
- Confirm before making significant changes
- Show progress through small demonstrations
- Get feedback on intermediate results

# INCREMENTAL IMPLEMENTATION
- Change one function at a time
- Test each small change when possible
- Build features incrementally
- Validate assumptions through small experiments
- Document insights as you discover them

# CONSTRAINTS
- ONE focused action per reasoning step
- Collaborate with user on decisions
- Progress through many small validated steps
- Build towards complete solution gradually%s]],
    config.role,
    config.approach,
    config.approach:gsub('^%w', string.upper),
    config.strengths,
    config.workflow,
    context_section
  )
end


---Chain of Thought configuration (for compatibility)
---@return table Configuration
function UnifiedReasoningPrompt.chain_of_thought_config()
  return {
    agent_type = 'Chain of Thought Programming',
    performance_tier = 'TOP 1%',
    identity_level = 'Staff Engineer',
    reasoning_approach = 'sequential logical excellence',
    quality_standard = 'zero-defect',
    discovery_priority = 'step-by-step efficiency',
    core_capabilities = {
      'Step-by-step analysis',
      'Progressive implementation',
      'Real-time validation',
      'Performance optimization',
    },
    specialized_patterns = { 'Code reviews', 'Systematic refactoring', 'Debug workflows', 'Test-driven development' },
    success_rate_target = 98,
  }
end

---Tree of Thoughts configuration (for compatibility)
---@return table Configuration
function UnifiedReasoningPrompt.tree_of_thoughts_config()
  return {
    agent_type = 'Tree of Thoughts Programming',
    performance_tier = 'TOP 1%',
    identity_level = 'Principal Architect',
    reasoning_approach = 'multiple solution path exploration',
    quality_standard = 'enterprise-grade',
    discovery_priority = 'comprehensive evaluation',
    core_capabilities = {
      'Solution space exploration',
      'Multi-dimensional evaluation',
      'Strategic selection',
      'Hybrid integration',
    },
    specialized_patterns = {
      'Architecture evaluation',
      'Algorithm optimization',
      'Technology assessment',
      'Risk analysis',
    },
    success_rate_target = 96,
  }
end

---Graph of Thoughts configuration (for compatibility)
---@return table Configuration
function UnifiedReasoningPrompt.graph_of_thoughts_config()
  return {
    agent_type = 'Graph of Thoughts Programming',
    performance_tier = 'TOP 0.1%',
    identity_level = 'Distinguished Engineer',
    reasoning_approach = 'interconnected system analysis',
    quality_standard = 'industry-leading',
    discovery_priority = 'system-wide optimization',
    core_capabilities = {
      'System topology analysis',
      'Dependency optimization',
      'Emergent behavior prediction',
      'Network effect utilization',
    },
    specialized_patterns = {
      'Microservices coordination',
      'Distributed systems design',
      'Network topology optimization',
      'System integration patterns',
    },
    success_rate_target = 97,
  }
end

---Get optimized config for reasoning type (for compatibility)
---@param reasoning_type string Type: 'chain', 'tree', or 'graph'
---@return table Configuration
function UnifiedReasoningPrompt.get_optimized_config(reasoning_type)
  if reasoning_type == 'chain' then
    return UnifiedReasoningPrompt.chain_of_thought_config()
  elseif reasoning_type == 'tree' then
    return UnifiedReasoningPrompt.tree_of_thoughts_config()
  elseif reasoning_type == 'graph' then
    return UnifiedReasoningPrompt.graph_of_thoughts_config()
  else
    error("Invalid reasoning type '" .. tostring(reasoning_type) .. "'. Must be 'chain', 'tree', or 'graph'.")
  end
end

---Generate prompt with config (for compatibility with old system)
---@param config table Configuration object
---@return string Generated prompt
function UnifiedReasoningPrompt.generate(config)
  -- Simple fallback for old system compatibility
  local reasoning_type = 'chain'
  if string.find(config.agent_type or '', '[Tt]ree') then
    reasoning_type = 'tree'
  elseif string.find(config.agent_type or '', '[Gg]raph') then
    reasoning_type = 'graph'
  end

  return UnifiedReasoningPrompt.generate_for_reasoning(reasoning_type)
end

return UnifiedReasoningPrompt
