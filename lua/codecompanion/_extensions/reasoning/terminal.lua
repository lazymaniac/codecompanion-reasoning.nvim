local Approvals = require('codecompanion.interactions.chat.tools.approvals')

local M = {}
local guard_key = '_codecompanion_reasoning_terminal_guard'

function M.install(tools)
  local chat = tools and tools.chat or nil
  if type(chat) ~= 'table' or type(chat.submit) ~= 'function' or rawget(chat, guard_key) then
    return false
  end

  local original = chat.submit
  local had_raw_submit = rawget(chat, 'submit') ~= nil
  local runtime_options = tools.tools_config and tools.tools_config.opts or {}
  local allow_auto_submit = runtime_options.auto_submit_success == true
    or (tools.bufnr ~= nil and Approvals:is_approved(tools.bufnr))
  local guard = {
    allow_auto_submit = allow_auto_submit,
    had_raw_submit = had_raw_submit,
    original = original,
  }

  local function guarded_submit(self, opts, ...)
    local current = rawget(self, guard_key)
    if not current then
      return original(self, opts, ...)
    end
    if type(opts) == 'table' and opts.auto_submit then
      if current.allow_auto_submit then
        current.allow_auto_submit = false
        return current.original(self, opts, ...)
      end
      if type(opts.callback) == 'function' then
        opts.callback()
      end
      return nil
    end
    return current.original(self, opts, ...)
  end

  guard.wrapper = guarded_submit
  rawset(chat, guard_key, guard)
  rawset(chat, 'submit', guarded_submit)
  return true
end

function M.clear(chat)
  local guard = type(chat) == 'table' and rawget(chat, guard_key) or nil
  if not guard then
    return false
  end
  if rawget(chat, 'submit') == guard.wrapper then
    if guard.had_raw_submit then
      rawset(chat, 'submit', guard.original)
    else
      rawset(chat, 'submit', nil)
    end
  end
  rawset(chat, guard_key, nil)
  return true
end

return M
