---@class CodeCompanion.Agent.UnifiedReasoningPrompt
---Streamlined system prompt generator for reasoning agents
local UnifiedReasoningPrompt = {}

local fmt = string.format

---Generate optimized prompt for reasoning agent
---@param reasoning_type string Type: 'chain', 'tree', or 'graph'
---@return string Complete system prompt
function UnifiedReasoningPrompt.generate_for_reasoning(reasoning_type)
  local configs = {
    chain = {
      role = 'Sequential coding problem solver',
      approach = 'step-by-step debugging and implementation',
      strengths = 'systematic debugging, feature implementation, refactoring',
      workflow = '1. Analyze → 2. Plan step → 3. Execute → 4. Validate → REPEAT UNTIL SOLUTION FOUND',
    },
    tree = {
      role = 'Multi-approach coding architect',
      approach = 'exploring multiple solution paths',
      strengths = 'architecture decisions, API design, solution comparison',
      workflow = '1. Generate options → 2. Evaluate → 3. Compare trade-offs → 4. Select optimal → 5. Execute → REPEAT UNTIL SOLUTION FOUND',
    },
    graph = {
      role = 'System complexity manager',
      approach = 'interconnected system analysis',
      strengths = 'microservices, dependencies, complex integrations',
      workflow = '1. Map dependencies → 2. Identify relationships → 3. Optimize connections → 4. Validate system',
    },
  }

  local config = configs[reasoning_type]
  if not config then
    error('Invalid reasoning type: ' .. tostring(reasoning_type))
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

# CRITICAL: AFTER INITIALIZATION
After calling initialize, you MUST immediately begin reasoning by calling add_step/add_thought repeatedly until the problem is solved.

NEVER stop after initialization - continue with reasoning steps:
1. Call add_step/add_thought with analysis
2. Call add_step/add_thought with reasoning  
3. Call add_step/add_thought with implementation tasks
4. Call add_step/add_thought with validation
5. REPEAT until problem is fully solved

# TOOL USAGE REQUIREMENTS
- ALWAYS use file editing tools to make code changes
- NEVER ask user to make changes manually
- Use `tool_discovery` to find file editing tools
- For file changes: search for tools like "edit", "write", "modify"

# IMPLEMENTATION RULES
- Write actual code using file editing tools
- Make real file modifications, not just suggestions
- Complete the full implementation workflow
- Test your changes when possible

# CONSTRAINTS
- Deliver production-ready code via tool usage
- Complete tasks automatically without user intervention
- Use tools proactively for all file operations]],
    config.role,
    config.approach,
    config.approach:gsub('^%w', string.upper),
    config.strengths,
    config.workflow
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

