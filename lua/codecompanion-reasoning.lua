--- codecompanion-reasoning.lua
--- Reasoning plugin entry point for CodeCompanion.
--- Provides a thin wrapper around the internal reasoning extension.

---@class CodeCompanion.ReasoningPlugin
local M = {}

--- Semantic version of the wrapper (mirrors the underlying extension if available).
M.version = '0.1.0'

--- Cached reference to the internal reasoning extension.
---@type table|nil
local _extension

--- Load the internal reasoning extension lazily.
--- @return table|nil ext The loaded extension or nil on failure.
local function load_extension()
  if _extension then
    return _extension
  end
  local ok, ext = pcall(require, 'codecompanion._extensions.reasoning')
  if ok then
    _extension = ext
    return _extension
  else
    vim.notify('[codecompanion-reasoning] Failed to load reasoning extension: ' .. tostring(ext), vim.log.levels.ERROR)
    return nil
  end
end

--- Setup the CodeCompanion Reasoning extension.
--- This forwards the configuration to the internal extension.
--- @param opts? table Optional configuration table.
--- @return table|nil config The extension configuration, or nil if loading failed.
function M.setup(opts)
  local ext = load_extension()
  if not ext then
    return nil
  end
  opts = opts or {}
  return ext.setup(opts)
end

--- Get the list of available reasoning tools.
--- @return table|nil tools Table of tool descriptors, or nil if loading failed.
function M.get_tools()
  local ext = load_extension()
  if not ext then
    return nil
  end
  return ext.exports.get_tools()
end

--- Prevent accidental modification of the public API after initialization.
setmetatable(M, {
  __newindex = function(_, key, _)
    error(string.format("[codecompanion-reasoning] Attempt to modify read‑only field '%s'", key), 2)
  end,
})

return M
