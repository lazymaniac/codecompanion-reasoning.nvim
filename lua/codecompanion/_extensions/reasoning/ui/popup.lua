---@class CodeCompanion.UI.Popup
---Interactive popup UI for user questions and responses
local Popup = {}

local fmt = string.format

-- UI Configuration
local UI_CONFIG = {
  -- Colors (using highlight groups)
  colors = {
    border = 'FloatBorder',
    title = 'FloatTitle',
    question = 'Question',
    context = 'Comment',
    option = 'Number',
    option_text = 'Normal',
    selected = 'CursorLine',
    input = 'Normal',
    hint = 'Comment',
  },
  -- Icons
  icons = {
    question = '❓',
    context = '💡',
    option = '▸',
    selected = '▶',
    input = '✏️',
    success = '✓',
    cancel = '✗',
  },
  -- Styling
  border_style = 'rounded',
  padding = 1,
}

---Wrap text to fit within specified width
---@param text string Text to wrap
---@param width number Maximum width
---@return string[] Wrapped lines
local function wrap_text(text, width)
  if not text or text == '' then
    return {}
  end

  local lines = {}
  local words = vim.split(text, '%s+')
  local current_line = ''

  for _, word in ipairs(words) do
    if #current_line + #word + 1 <= width then
      if current_line == '' then
        current_line = word
      else
        current_line = current_line .. ' ' .. word
      end
    else
      if current_line ~= '' then
        table.insert(lines, current_line)
      end
      current_line = word
    end
  end

  if current_line ~= '' then
    table.insert(lines, current_line)
  end

  return lines
end

---Create and show an interactive question popup
---@param question string The question to ask
---@param context? string Additional context
---@param options? string[] List of options
---@param callback function Callback with user response (response_text, cancelled)
function Popup.ask_question(question, context, options, callback)
  vim.schedule(function()
    question = question or 'No question provided'
    context = context or ''
    options = options or {}

    -- Calculate optimal width based on content and screen size
    local max_width = math.floor(vim.o.columns * 0.7)
    local min_width = 50
    local content_width = math.max(min_width, math.min(max_width, 80))

    -- Create enhanced content with proper formatting and icons
    local popup_lines = {}
    local highlights = {}

    -- Header with AI icon
    table.insert(popup_lines, '')
    table.insert(popup_lines, fmt('  🤖 AI Assistant'))
    table.insert(highlights, { line = #popup_lines - 1, col = 2, end_col = -1, group = UI_CONFIG.colors.title })
    table.insert(popup_lines, '')

    -- Question section with icon and proper wrapping
    table.insert(popup_lines, fmt('  %s Question', UI_CONFIG.icons.question))
    table.insert(highlights, { line = #popup_lines - 1, col = 2, end_col = 4, group = UI_CONFIG.colors.question })
    table.insert(popup_lines, '')

    local question_lines = wrap_text(question, content_width - 6)
    for _, line in ipairs(question_lines) do
      table.insert(popup_lines, fmt('    %s', line))
      table.insert(highlights, { line = #popup_lines - 1, col = 4, end_col = -1, group = UI_CONFIG.colors.question })
    end

    -- Context section (if provided)
    if context and context ~= '' then
      table.insert(popup_lines, '')
      table.insert(popup_lines, fmt('  %s Context', UI_CONFIG.icons.context))
      table.insert(highlights, { line = #popup_lines - 1, col = 2, end_col = 4, group = UI_CONFIG.colors.context })
      table.insert(popup_lines, '')

      local context_lines = wrap_text(context, content_width - 6)
      for _, line in ipairs(context_lines) do
        table.insert(popup_lines, fmt('    %s', line))
        table.insert(highlights, { line = #popup_lines - 1, col = 4, end_col = -1, group = UI_CONFIG.colors.context })
      end
    end

    -- Options section (if provided)
    if #options > 0 then
      table.insert(popup_lines, '')
      table.insert(popup_lines, '  📋 Options')
      table.insert(highlights, { line = #popup_lines - 1, col = 2, end_col = -1, group = UI_CONFIG.colors.title })
      table.insert(popup_lines, '')

      for i, option in ipairs(options) do
        local option_lines = wrap_text(option, content_width - 12)
        local first_line = true
        for _, opt_line in ipairs(option_lines) do
          if first_line then
            table.insert(popup_lines, fmt('    [%d] %s', i, opt_line))
            table.insert(highlights, { line = #popup_lines - 1, col = 4, end_col = 7, group = UI_CONFIG.colors.option })
            first_line = false
          else
            table.insert(popup_lines, fmt('        %s', opt_line))
          end
          table.insert(
            highlights,
            { line = #popup_lines - 1, col = 8, end_col = -1, group = UI_CONFIG.colors.option_text }
          )
        end
      end
      table.insert(popup_lines, '')
      table.insert(popup_lines, '  💬 Type a number (1-' .. #options .. ') or your custom response')
    else
      table.insert(popup_lines, '')
      table.insert(popup_lines, '  💬 Your response')
    end
    table.insert(highlights, { line = #popup_lines - 1, col = 2, end_col = -1, group = UI_CONFIG.colors.hint })

    -- Add some spacing and instructions
    table.insert(popup_lines, '')
    table.insert(popup_lines, '')
    table.insert(
      popup_lines,
      fmt('  %s Enter to submit  •  %s Esc to cancel', UI_CONFIG.icons.success, UI_CONFIG.icons.cancel)
    )
    table.insert(highlights, { line = #popup_lines - 1, col = 2, end_col = -1, group = UI_CONFIG.colors.hint })

    -- Calculate dimensions
    local display_width = content_width + 4
    local display_height = #popup_lines + 4 -- Extra space for input and padding

    -- Ensure popup fits on screen
    display_width = math.min(display_width, vim.o.columns - 4)
    display_height = math.min(display_height, vim.o.lines - 4)

    -- Create main content buffer
    local popup_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(popup_buf, 0, -1, false, popup_lines)
    vim.api.nvim_buf_set_option(popup_buf, 'modifiable', false)
    vim.api.nvim_buf_set_option(popup_buf, 'bufhidden', 'wipe')
    vim.api.nvim_buf_set_option(popup_buf, 'filetype', 'markdown')

    -- Apply syntax highlighting
    local ns_id = vim.api.nvim_create_namespace('ai_question_popup')
    for _, hl in ipairs(highlights) do
      vim.api.nvim_buf_add_highlight(popup_buf, ns_id, hl.group, hl.line, hl.col, hl.end_col)
    end

    -- Create input buffer with better styling
    local input_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(input_buf, 'bufhidden', 'wipe')
    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { '  ' .. UI_CONFIG.icons.input .. ' ' })

    -- Main popup window with enhanced styling
    local popup_opts = {
      relative = 'editor',
      width = display_width,
      height = display_height - 3,
      col = math.floor((vim.o.columns - display_width) / 2),
      row = math.floor((vim.o.lines - display_height) / 2),
      style = 'minimal',
      border = UI_CONFIG.border_style,
      title = fmt(' %s AI Question %s ', '🤖', '❓'),
      title_pos = 'center',
      zindex = 100,
    }

    local popup_win = vim.api.nvim_open_win(popup_buf, false, popup_opts)
    vim.api.nvim_win_set_option(popup_win, 'winhl', 'FloatBorder:' .. UI_CONFIG.colors.border)

    -- Input window with border
    local input_opts = {
      relative = 'editor',
      width = display_width - 2,
      height = 1,
      col = popup_opts.col + 1,
      row = popup_opts.row + display_height - 2,
      style = 'minimal',
      border = { '─', '─', '─', '│', '┘', '─', '└', '│' },
      zindex = 101,
    }

    local input_win = vim.api.nvim_open_win(input_buf, true, input_opts)
    vim.api.nvim_win_set_option(input_win, 'winhl', 'FloatBorder:' .. UI_CONFIG.colors.border)

    -- Position cursor at the end of the input line
    local input_line = vim.api.nvim_buf_get_lines(input_buf, 0, 1, false)[1] or ''
    vim.api.nvim_win_set_cursor(input_win, { 1, #input_line })
    vim.api.nvim_win_set_option(input_win, 'cursorline', false)

    -- Animation: fade in effect (simple implementation)
    vim.api.nvim_win_set_option(popup_win, 'winblend', 20)
    vim.api.nvim_win_set_option(input_win, 'winblend', 20)
    vim.defer_fn(function()
      if vim.api.nvim_win_is_valid(popup_win) then
        vim.api.nvim_win_set_option(popup_win, 'winblend', 0)
      end
      if vim.api.nvim_win_is_valid(input_win) then
        vim.api.nvim_win_set_option(input_win, 'winblend', 0)
      end
    end, 150)

    -- Enhanced response handling
    local function handle_response(response, show_feedback)
      show_feedback = show_feedback ~= false

      -- Extract actual response text (remove the input icon)
      if response then
        response = response:gsub('^%s*' .. UI_CONFIG.icons.input .. '%s*', '')
        response = vim.trim(response)
        if response == '' then
          response = nil
        end
      end

      -- Show brief feedback before closing
      if show_feedback and (response or not response) then
        local feedback_icon = response and UI_CONFIG.icons.success or UI_CONFIG.icons.cancel
        local feedback_text = response and 'Response submitted!' or 'Cancelled'

        -- Update input buffer to show feedback
        vim.api.nvim_buf_set_option(input_buf, 'modifiable', true)
        vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { fmt('  %s %s', feedback_icon, feedback_text) })
        vim.api.nvim_buf_set_option(input_buf, 'modifiable', false)

        -- Highlight feedback
        local feedback_ns = vim.api.nvim_create_namespace('feedback')
        local hl_group = response and 'DiagnosticOk' or 'DiagnosticWarn'
        vim.api.nvim_buf_add_highlight(input_buf, feedback_ns, hl_group, 0, 0, -1)

        -- Close after brief delay
        vim.defer_fn(function()
          handle_response(response, false)
        end, 800)
        return
      end

      -- Close windows with fade out
      local function close_windows()
        if vim.api.nvim_win_is_valid(popup_win) then
          vim.api.nvim_win_close(popup_win, true)
        end
        if vim.api.nvim_win_is_valid(input_win) then
          vim.api.nvim_win_close(input_win, true)
        end
      end

      -- Fade out effect
      if vim.api.nvim_win_is_valid(popup_win) then
        vim.api.nvim_win_set_option(popup_win, 'winblend', 20)
      end
      if vim.api.nvim_win_is_valid(input_win) then
        vim.api.nvim_win_set_option(input_win, 'winblend', 20)
      end

      vim.defer_fn(close_windows, 100)

      if response and response ~= '' then
        -- Parse response for option selection
        local selected_option = nil
        local parsed_response = response

        if #options > 0 then
          local option_num = tonumber(response:match('^%s*(%d+)'))
          if option_num and option_num >= 1 and option_num <= #options then
            selected_option = options[option_num]
            parsed_response = fmt('Option %d: %s', option_num, selected_option)
          end
        end

        vim.defer_fn(function()
          callback(parsed_response, false, selected_option)
        end, 150)
      else
        -- User cancelled
        vim.defer_fn(function()
          callback(nil, true)
        end, 150)
      end
    end

    -- Enhanced key mappings with better user experience
    local function setup_mappings()
      -- Number key shortcuts for options
      if #options > 0 then
        for i = 1, math.min(#options, 9) do
          vim.api.nvim_buf_set_keymap(input_buf, 'i', tostring(i), '', {
            noremap = true,
            silent = true,
            callback = function()
              -- Clear current input and set the number
              local new_line = fmt('  %s %d', UI_CONFIG.icons.input, i)
              vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { new_line })
              vim.api.nvim_win_set_cursor(input_win, { 1, #new_line })
            end,
          })
        end
      end

      -- Enhanced Enter to submit
      vim.api.nvim_buf_set_keymap(input_buf, 'i', '<CR>', '', {
        noremap = true,
        silent = true,
        callback = function()
          local response = vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)[1] or ''
          handle_response(response)
        end,
      })

      -- Normal mode mappings
      vim.api.nvim_buf_set_keymap(input_buf, 'n', '<CR>', '', {
        noremap = true,
        silent = true,
        callback = function()
          local response = vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)[1] or ''
          handle_response(response)
        end,
      })

      vim.api.nvim_buf_set_keymap(input_buf, 'n', '<Esc>', '', {
        noremap = true,
        silent = true,
        callback = function()
          handle_response(nil)
        end,
      })

      -- Tab completion for options
      if #options > 0 then
        vim.api.nvim_buf_set_keymap(input_buf, 'i', '<Tab>', '', {
          noremap = true,
          silent = true,
          callback = function()
            -- Cycle through options
            local current_text = vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)[1] or ''
            local current_num = tonumber(current_text:match('(%d+)')) or 0
            local next_num = (current_num % #options) + 1

            local new_line = fmt('  %s %d', UI_CONFIG.icons.input, next_num)
            vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { new_line })
            vim.api.nvim_win_set_cursor(input_win, { 1, #new_line })
          end,
        })
      end
    end

    setup_mappings()

    -- Auto-complete setup for better UX
    vim.api.nvim_buf_set_option(input_buf, 'modifiable', true)

    -- Start in insert mode at the right position
    vim.cmd('startinsert')
    vim.defer_fn(function()
      if vim.api.nvim_win_is_valid(input_win) then
        local current_line = vim.api.nvim_buf_get_lines(input_buf, 0, 1, false)[1] or ''
        vim.api.nvim_win_set_cursor(input_win, { 1, #current_line })
      end
    end, 50)
  end)
end

return Popup
