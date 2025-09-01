-- CodeCompanion Reasoning Extension
-- Provides advanced reasoning tools for CodeCompanion.nvim

if vim.g.loaded_codecompanion_reasoning then
  return
end
vim.g.loaded_codecompanion_reasoning = 1

-- Check if CodeCompanion is available
local ok, _ = pcall(require, "codecompanion")
if not ok then
  vim.notify("CodeCompanion Reasoning: CodeCompanion.nvim not found", vim.log.levels.WARN)
  return
end

-- Test that the extension can be loaded
local extension_ok, extension = pcall(require, "codecompanion._extensions.reasoning")
if not extension_ok then
  vim.notify("CodeCompanion Reasoning: Failed to load extension - " .. tostring(extension), vim.log.levels.ERROR)
elseif type(extension.setup) ~= "function" then
  vim.notify("CodeCompanion Reasoning: Extension missing setup function", vim.log.levels.ERROR)
else
end
