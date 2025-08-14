---@class CodeCompanion.ReasoningPlugin
local M = {}

---Setup the CodeCompanion Reasoning extension
---@param opts? table Configuration options
---@return table Extension configuration
function M.setup(opts)
  opts = opts or {}

  -- Load and setup the extension
  local extension = require("codecompanion._extensions.reasoning")
  return extension.setup(opts)
end

---Get the available reasoning tools
---@return table Available tools
function M.get_tools()
  local extension = require("codecompanion._extensions.reasoning")
  return extension.exports.get_tools()
end

return M
