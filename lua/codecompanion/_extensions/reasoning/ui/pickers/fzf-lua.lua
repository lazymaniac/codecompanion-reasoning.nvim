---@class CodeCompanion.Reasoning.FzfLuaPicker : CodeCompanion.Reasoning.DefaultPicker
local FzfLuaPicker = setmetatable({}, {
  __index = require('codecompanion._extensions.reasoning.ui.pickers.default'),
})
FzfLuaPicker.__index = FzfLuaPicker

---Create new fzf-lua picker instance
---@param config table Configuration for the picker
---@return CodeCompanion.Reasoning.FzfLuaPicker
function FzfLuaPicker.new(config)
  local self = setmetatable({}, FzfLuaPicker)
  self.config = config
  return self
end

---Browse sessions using fzf-lua
function FzfLuaPicker:browse()
  -- Check if fzf-lua is available
  local fzf_ok, fzf = pcall(require, 'fzf-lua')
  if not fzf_ok then
    vim.notify('fzf-lua not available, falling back to default picker', vim.log.levels.WARN)
    return require('codecompanion._extensions.reasoning.ui.pickers.default').browse(self)
  end

  -- Prepare entries for fzf
  local entries = {}
  local entry_map = {}

  for i, session in ipairs(self.config.items) do
    local display = self:format_entry(session)
    entries[i] = display
    entry_map[display] = session
  end

  -- Configure fzf options
  local opts = {
    prompt = (self.config.title or 'Chat Sessions') .. '> ',
    winopts = {
      title = ' ' .. (self.config.title or 'Chat Sessions') .. ' ',
      title_pos = 'center',
      height = 0.8,
      width = 0.9,
      preview = {
        layout = 'horizontal',
        horizontal = 'right:50%',
      },
    },
    previewer = function(items, _)
      -- Get the selected item
      local display = items[1]
      local session = entry_map[display]
      if not session then
        return { 'No session selected' }
      end

      return self:get_preview(session)
    end,
    actions = {
      ['default'] = function(selected)
        local display = selected[1]
        local session = entry_map[display]
        if session then
          self.config.handlers.on_select(session)
        end
      end,
      ['ctrl-d'] = function(selected)
        local sessions_to_delete = {}
        for _, display in ipairs(selected) do
          local session = entry_map[display]
          if session then
            table.insert(sessions_to_delete, session)
          end
        end
        if #sessions_to_delete > 0 then
          self.config.handlers.on_delete(sessions_to_delete)
        end
      end,
    },
  }

  -- Add rename and duplicate actions if handlers exist
  if self.config.handlers.on_rename then
    opts.actions['ctrl-r'] = function(selected)
      local display = selected[1]
      local session = entry_map[display]
      if session then
        self.config.handlers.on_rename(session)
      end
    end
  end

  if self.config.handlers.on_duplicate then
    opts.actions['ctrl-y'] = function(selected)
      local display = selected[1]
      local session = entry_map[display]
      if session then
        self.config.handlers.on_duplicate(session)
      end
    end
  end

  -- Show help in the header
  local help_lines = {
    'Enter: select',
    'Ctrl-D: delete',
  }

  if self.config.handlers.on_rename then
    table.insert(help_lines, 'Ctrl-R: rename')
  end

  if self.config.handlers.on_duplicate then
    table.insert(help_lines, 'Ctrl-Y: duplicate')
  end

  opts.winopts.title = opts.winopts.title .. ' (' .. table.concat(help_lines, ', ') .. ')'

  fzf.fzf_exec(entries, opts)
end

return FzfLuaPicker
