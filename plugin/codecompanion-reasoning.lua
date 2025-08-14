-- CodeCompanion Reasoning Extension
-- Provides advanced reasoning tools for CodeCompanion.nvim

if vim.g.loaded_codecompanion_reasoning then
  return
end
vim.g.loaded_codecompanion_reasoning = 1

-- Check if CodeCompanion is available
local ok, codecompanion = pcall(require, "codecompanion")
if not ok then
  vim.notify("CodeCompanion Reasoning: CodeCompanion.nvim not found", vim.log.levels.WARN)
  return
end

-- Register the reasoning extension
local extension_ok, extension = pcall(require, "codecompanion._extensions.reasoning")
if extension_ok then
  codecompanion.register_extension("reasoning", {
    callback = extension,
    opts = {
      enabled = true,
    },
  })
else
  vim.notify("CodeCompanion Reasoning: Failed to load extension", vim.log.levels.ERROR)
end