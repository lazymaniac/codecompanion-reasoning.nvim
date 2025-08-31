---@class CodeCompanion.Reasoning.TelescopePicker : CodeCompanion.Reasoning.DefaultPicker
local TelescopePicker = setmetatable({}, {
  __index = require('codecompanion._extensions.reasoning.ui.pickers.default'),
})
TelescopePicker.__index = TelescopePicker

---Create new Telescope picker instance
---@param config table Configuration for the picker
---@return CodeCompanion.Reasoning.TelescopePicker
function TelescopePicker.new(config)
  local self = setmetatable({}, TelescopePicker)
  self.config = config
  return self
end

---Browse sessions using Telescope
function TelescopePicker:browse()
  -- Check if telescope is available
  local telescope_ok, telescope = pcall(require, 'telescope')
  if not telescope_ok then
    vim.notify('Telescope not available, falling back to default picker', vim.log.levels.WARN)
    return require('codecompanion._extensions.reasoning.ui.pickers.default').browse(self)
  end
  require('telescope.pickers')
    .new({}, {
      prompt_title = self.config.title or 'Chat Sessions',
      finder = require('telescope.finders').new_table({
        results = self.config.items,
        entry_maker = function(entry)
          local display_title = self:format_entry(entry)

          -- Create telescope entry with enhanced fields
          return vim.tbl_extend('keep', {
            value = entry,
            display = display_title,
            ordinal = self:get_item_title(entry),
            name = self:get_item_title(entry),
            item_id = self:get_item_id(entry),
            -- Additional fields for sorting/filtering
            created_at = entry.created_at,
            model = entry.model,
            project_root = entry.project_root,
            message_count = entry.total_messages,
          }, entry)
        end,
      }),
      sorter = require('telescope.config').values.generic_sorter({}),
      previewer = require('telescope.previewers').new_buffer_previewer({
        title = self:get_item_name_singular():gsub('^%l', string.upper) .. ' Preview',
        define_preview = function(preview_state, entry)
          local lines = self:get_preview(entry.value)
          if not lines then
            return
          end
          vim.bo[preview_state.state.bufnr].filetype = 'markdown'
          vim.api.nvim_buf_set_lines(preview_state.state.bufnr, 0, -1, false, lines)
        end,
      }),
      attach_mappings = function(prompt_bufnr)
        local actions = require('telescope.actions')
        local action_state = require('telescope.actions.state')

        -- Function to handle deletion of selected items
        local delete_selections = function()
          local picker = action_state.get_current_picker(prompt_bufnr)
          local selections = picker:get_multi_selection()

          if #selections == 0 then
            -- If no multi-selection, use current selection
            local selection = action_state.get_selected_entry()
            if selection then
              selections = { selection }
            end
          end

          actions.close(prompt_bufnr)

          -- Extract session data from selections
          local sessions_to_delete = {}
          for _, selection in ipairs(selections) do
            table.insert(sessions_to_delete, selection.value)
          end

          if #sessions_to_delete > 0 then
            self.config.handlers.on_delete(sessions_to_delete)
          end
        end

        -- Function to handle renaming
        local rename_selection = function()
          local selection = action_state.get_selected_entry()
          if not selection then
            return
          end
          actions.close(prompt_bufnr)
          if self.config.handlers.on_rename then
            self.config.handlers.on_rename(selection.value)
          end
        end

        -- Function to handle duplication
        local duplicate_selection = function()
          local selection = action_state.get_selected_entry()
          if not selection then
            return
          end
          actions.close(prompt_bufnr)
          if self.config.handlers.on_duplicate then
            self.config.handlers.on_duplicate(selection.value)
          end
        end

        -- Select action (main selection)
        actions.select_default:replace(function()
          local selection = action_state.get_selected_entry()
          if not selection then
            return
          end
          actions.close(prompt_bufnr)
          self.config.handlers.on_select(selection.value)
        end)

        -- Delete items (normal mode and insert mode)
        if self.config.keymaps and self.config.keymaps.delete then
          vim.keymap.set({ 'n' }, self.config.keymaps.delete.n or 'd', delete_selections, {
            buffer = prompt_bufnr,
            silent = true,
            nowait = true,
          })
          vim.keymap.set({ 'i' }, self.config.keymaps.delete.i or '<M-d>', delete_selections, {
            buffer = prompt_bufnr,
            silent = true,
            nowait = true,
          })
        end

        -- Rename items (if supported)
        if self.config.keymaps and self.config.keymaps.rename and self.config.handlers.on_rename then
          vim.keymap.set({ 'n' }, self.config.keymaps.rename.n or 'r', rename_selection, {
            buffer = prompt_bufnr,
            silent = true,
            nowait = true,
          })
          vim.keymap.set({ 'i' }, self.config.keymaps.rename.i or '<M-r>', rename_selection, {
            buffer = prompt_bufnr,
            silent = true,
            nowait = true,
          })
        end

        -- Duplicate items (if supported)
        if self.config.keymaps and self.config.keymaps.duplicate and self.config.handlers.on_duplicate then
          vim.keymap.set({ 'n' }, self.config.keymaps.duplicate.n or '<C-y>', duplicate_selection, {
            buffer = prompt_bufnr,
            silent = true,
            nowait = true,
          })
          vim.keymap.set({ 'i' }, self.config.keymaps.duplicate.i or '<C-y>', duplicate_selection, {
            buffer = prompt_bufnr,
            silent = true,
            nowait = true,
          })
        end

        return true
      end,
    })
    :find()
end

return TelescopePicker

