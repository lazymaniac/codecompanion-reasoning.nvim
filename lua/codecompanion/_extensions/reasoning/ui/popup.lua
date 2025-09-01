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
    option = 'Number',
    option_text = 'Normal',
    selected = 'CursorLine',
    input = 'Normal',
    hint = 'Comment',
  },
  -- Icons
  icons = {
    question = '❓',
    option = '▸',
    selected = '▶',
    input = '✏️',
    success = '✓',
    cancel = '✗',
  },
  -- Styling
  border_style = 'rounded',
  padding = 1,
  max_width_ratio = 0.7,
  min_width = 50,
  default_width = 80,
}

-- Utility Functions

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

---Calculate optimal popup dimensions based on content and screen size
---@param content_lines string[] Content lines to display
---@return number width, number height, number content_width
local function calculate_dimensions(content_lines)
  local max_width = math.floor(vim.o.columns * UI_CONFIG.max_width_ratio)
  local min_width = UI_CONFIG.min_width
  local content_width = math.max(min_width, math.min(max_width, UI_CONFIG.default_width))

  local display_width = content_width + 4
  local display_height = #content_lines + 4 -- Extra space for input and padding

  -- Ensure popup fits on screen
  display_width = math.min(display_width, vim.o.columns - 4)
  display_height = math.min(display_height, vim.o.lines - 4)

  return display_width, display_height, content_width
end

---Build formatted content lines and highlights for the popup
---@param question string The question to display
---@param options string[] List of options
---@param content_width number Available content width
---@return string[] lines, table[] highlights
local function build_content(question, options, content_width)
  local popup_lines = {}
  local highlights = {}

  -- Helper function to add highlighted line
  local function add_line(text, highlight_group, indent)
    indent = indent or 0
    local indented_text = string.rep(' ', indent) .. text
    table.insert(popup_lines, indented_text)
    if highlight_group then
      table.insert(highlights, {
        line = #popup_lines - 1,
        col = indent,
        end_col = -1,
        group = highlight_group,
      })
    end
  end

  -- Header
  add_line('', nil)
  add_line('🤖 AI Assistant', UI_CONFIG.colors.title, 2)
  add_line('', nil)

  -- Question section
  add_line(fmt('%s Question', UI_CONFIG.icons.question), UI_CONFIG.colors.question, 2)
  add_line('', nil)

  local question_lines = wrap_text(question, content_width - 6)
  for _, line in ipairs(question_lines) do
    add_line(line, UI_CONFIG.colors.question, 4)
  end

  -- Options section
  if options and #options > 0 then
    add_line('', nil)
    add_line('📋 Options', UI_CONFIG.colors.title, 2)
    add_line('', nil)

    for i, option in ipairs(options) do
      local option_lines = wrap_text(option, content_width - 12)
      for j, opt_line in ipairs(option_lines) do
        if j == 1 then
          local option_prefix = fmt('[%d] ', i)
          local full_line = option_prefix .. opt_line
          add_line(full_line, nil, 4)
          -- Add separate highlights for number and text with proper bounds checking
          local line_idx = #popup_lines - 1
          local actual_line = popup_lines[line_idx + 1] -- 1-based indexing for the actual line
          local line_len = #actual_line

          -- Highlight the option number part
          local number_end_col = math.min(4 + #option_prefix, line_len)
          if number_end_col > 4 then
            table.insert(highlights, {
              line = line_idx,
              col = 4,
              end_col = number_end_col,
              group = UI_CONFIG.colors.option,
            })
          end

          -- Highlight the option text part
          local text_start_col = 4 + #option_prefix
          if text_start_col < line_len then
            table.insert(highlights, {
              line = line_idx,
              col = text_start_col,
              end_col = -1,
              group = UI_CONFIG.colors.option_text,
            })
          end
        else
          add_line(opt_line, UI_CONFIG.colors.option_text, 8)
        end
      end
    end

    add_line('', nil)
    add_line('💬 Type a number (1-' .. #options .. ') or your custom response', UI_CONFIG.colors.hint, 2)
  else
    add_line('', nil)
    add_line('💬 Your response', UI_CONFIG.colors.hint, 2)
  end

  -- Instructions
  add_line('', nil)
  add_line('', nil)
  add_line(
    fmt('%s Enter to submit  •  %s Esc to cancel', UI_CONFIG.icons.success, UI_CONFIG.icons.cancel),
    UI_CONFIG.colors.hint,
    2
  )

  return popup_lines, highlights
end

---Create and configure popup buffers and windows
---@param popup_lines string[] Content lines
---@param highlights table[] Highlight definitions
---@param width number Window width
---@param height number Window height
---@return number popup_buf, number input_buf, number popup_win, number input_win
local function create_windows(popup_lines, highlights, width, height)
  -- Create main content buffer
  local popup_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(popup_buf, 0, -1, false, popup_lines)
  vim.bo[popup_buf].bufhidden = 'wipe'
  vim.bo[popup_buf].filetype = 'markdown'

  -- Apply syntax highlighting using extmarks
  local ns_id = vim.api.nvim_create_namespace('ai_question_popup')
  for _, hl in ipairs(highlights) do
    -- Get the actual line content to validate bounds
    local line_content = vim.api.nvim_buf_get_lines(popup_buf, hl.line, hl.line + 1, false)[1] or ''
    local line_len = #line_content

    -- Validate and adjust column positions for 0-based indexing
    -- start_col must be < line_len (or == 0 for empty lines)
    local start_col = hl.col
    if line_len == 0 then
      start_col = math.min(start_col, 0)
    else
      start_col = math.min(start_col, line_len - 1)
    end

    local end_col = hl.end_col
    if end_col ~= -1 then
      -- end_col can be equal to line_len (exclusive end position)
      end_col = math.min(end_col, line_len)
      -- Ensure end_col is not before start_col
      end_col = math.max(end_col, start_col + 1)
    end

    -- Only create extmark if start_col is valid
    if start_col >= 0 and (line_len == 0 or start_col < line_len) then
      -- Ensure buffer is modifiable before adding extmarks
      local was_modifiable = vim.bo[popup_buf].modifiable
      if not was_modifiable then
        vim.bo[popup_buf].modifiable = true
      end

      local extmark_opts = {
        hl_group = hl.group,
        strict = false,
      }

      if end_col ~= -1 and end_col > start_col and end_col <= line_len then
        extmark_opts.end_col = end_col
      end

      local line_count = vim.api.nvim_buf_line_count(popup_buf)
      if hl.line >= 0 and hl.line < line_count then
        pcall(vim.api.nvim_buf_set_extmark, popup_buf, ns_id, hl.line, start_col, extmark_opts)
      end

      if not was_modifiable then
        vim.bo[popup_buf].modifiable = false
      end
    end
  end

  -- Make buffer non-modifiable after all setup is complete
  vim.bo[popup_buf].modifiable = false

  -- Create input buffer
  local input_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[input_buf].bufhidden = 'wipe'
  vim.bo[input_buf].modifiable = true
  vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { '  ' .. UI_CONFIG.icons.input .. ' ' })

  -- Main popup window
  local popup_opts = {
    relative = 'editor',
    width = width,
    height = height - 3,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    style = 'minimal',
    border = UI_CONFIG.border_style,
    title = fmt(' %s AI Question %s ', '🤖', '❓'),
    title_pos = 'center',
    zindex = 100,
  }

  local popup_win = vim.api.nvim_open_win(popup_buf, false, popup_opts)
  vim.wo[popup_win].winhl = 'FloatBorder:' .. UI_CONFIG.colors.border

  -- Input window
  local input_opts = {
    relative = 'editor',
    width = width - 2,
    height = 1,
    col = popup_opts.col + 1,
    row = popup_opts.row + height - 2,
    style = 'minimal',
    border = { '─', '─', '─', '│', '┘', '─', '└', '│' },
    zindex = 101,
  }

  local input_win = vim.api.nvim_open_win(input_buf, true, input_opts)
  vim.wo[input_win].winhl = 'FloatBorder:' .. UI_CONFIG.colors.border

  return popup_buf, input_buf, popup_win, input_win
end

---Apply fade-in animation to windows
---@param popup_win number Popup window handle
---@param input_win number Input window handle
local function apply_fade_in(popup_win, input_win)
  vim.wo[popup_win].winblend = 20
  vim.wo[input_win].winblend = 20

  vim.defer_fn(function()
    if vim.api.nvim_win_is_valid(popup_win) then
      vim.wo[popup_win].winblend = 0
    end
    if vim.api.nvim_win_is_valid(input_win) then
      vim.wo[input_win].winblend = 0
    end
  end, 150)
end

---Set up keyboard mappings for the input buffer
---@param input_buf number Input buffer handle
---@param input_win number Input window handle
---@param options string[] Available options
---@param callback function Response callback
local function setup_key_mappings(input_buf, input_win, options, callback)
  -- Number shortcuts for options
  if #options > 0 then
    for i = 1, math.min(#options, 9) do
      vim.api.nvim_buf_set_keymap(input_buf, 'i', tostring(i), '', {
        noremap = true,
        silent = true,
        callback = function()
          local new_line = fmt('  %s %d', UI_CONFIG.icons.input, i)
          vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { new_line })
          vim.api.nvim_win_set_cursor(input_win, { 1, #new_line })
        end,
      })
    end

    -- Tab completion for cycling through options
    vim.api.nvim_buf_set_keymap(input_buf, 'i', '<Tab>', '', {
      noremap = true,
      silent = true,
      callback = function()
        local current_text = vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)[1] or ''
        local current_num = tonumber(current_text:match('(%d+)')) or 0
        local next_num = (current_num % #options) + 1

        local new_line = fmt('  %s %d', UI_CONFIG.icons.input, next_num)
        vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { new_line })
        vim.api.nvim_win_set_cursor(input_win, { 1, #new_line })
      end,
    })
  end

  -- Enter to submit (both insert and normal mode)
  local submit_handler = function()
    local response = vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)[1] or ''
    callback(response)
  end

  vim.api.nvim_buf_set_keymap(input_buf, 'i', '<CR>', '', {
    noremap = true,
    silent = true,
    callback = submit_handler,
  })

  vim.api.nvim_buf_set_keymap(input_buf, 'n', '<CR>', '', {
    noremap = true,
    silent = true,
    callback = submit_handler,
  })

  -- Escape to cancel
  vim.api.nvim_buf_set_keymap(input_buf, 'n', '<Esc>', '', {
    noremap = true,
    silent = true,
    callback = function()
      callback(nil)
    end,
  })
end

---Handle response processing and window cleanup
---@param response? string User response
---@param options string[] Available options
---@param popup_win number Popup window handle
---@param input_win number Input window handle
---@param input_buf number Input buffer handle
---@param final_callback function Final callback to execute
local function process_response(response, options, popup_win, input_win, input_buf, final_callback)
  -- Extract actual response text (remove the input icon)
  if response then
    response = response:gsub('^%s*' .. UI_CONFIG.icons.input .. '%s*', '')
    response = vim.trim(response)
    if response == '' then
      response = nil
    end
  end

  -- Show feedback
  local feedback_icon = response and UI_CONFIG.icons.success or UI_CONFIG.icons.cancel
  local feedback_text = response and 'Response submitted!' or 'Cancelled'

  vim.bo[input_buf].modifiable = true
  vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { fmt('  %s %s', feedback_icon, feedback_text) })
  vim.bo[input_buf].modifiable = false

  -- Highlight feedback using extmarks
  local feedback_ns = vim.api.nvim_create_namespace('feedback')
  local hl_group = response and 'DiagnosticOk' or 'DiagnosticWarn'

  -- Get line content to validate bounds
  local line_content = vim.api.nvim_buf_get_lines(input_buf, 0, 1, false)[1] or ''
  local line_len = #line_content

  -- Only create extmark if line has content
  if line_len > 0 then
    vim.api.nvim_buf_set_extmark(input_buf, feedback_ns, 0, 0, {
      end_col = line_len,
      hl_group = hl_group,
      strict = false,
    })
  end

  -- Close windows after delay
  vim.defer_fn(function()
    -- Apply fade out
    if vim.api.nvim_win_is_valid(popup_win) then
      vim.wo[popup_win].winblend = 20
    end
    if vim.api.nvim_win_is_valid(input_win) then
      vim.wo[input_win].winblend = 20
    end

    vim.defer_fn(function()
      if vim.api.nvim_win_is_valid(popup_win) then
        vim.api.nvim_win_close(popup_win, true)
      end
      if vim.api.nvim_win_is_valid(input_win) then
        vim.api.nvim_win_close(input_win, true)
      end

      -- Parse and return response
      if response and response ~= '' then
        local selected_option = nil
        local parsed_response = response

        if #options > 0 then
          local option_num = tonumber(response:match('^%s*(%d+)'))
          if option_num and option_num >= 1 and option_num <= #options then
            selected_option = options[option_num]
            parsed_response = fmt('Option %d: %s', option_num, selected_option)
          end
        end

        final_callback(parsed_response, false, selected_option)
      else
        final_callback(nil, true)
      end
    end, 100)
  end, 800)
end

-- Main API

---Show a generic list picker with selectable items
---@param opts table Options for the picker
function Popup.show(opts)
  opts = opts or {}

  local title = opts.title or 'Select Item'
  local items = opts.items or {}
  local on_select = opts.on_select or function() end
  local on_delete = opts.on_delete
  local keymaps = opts.keymaps or {}
  local help_text = opts.help_text or {}

  if #items == 0 then
    vim.notify('No items to display', vim.log.levels.INFO)
    return
  end

  -- Create picker buffer
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].bufhidden = 'wipe'
  vim.bo[bufnr].filetype = 'codecompanion-picker'

  -- Build content
  local lines = {}
  local current_line = 0

  -- Title
  table.insert(lines, '')
  table.insert(lines, string.format('  %s', title))
  table.insert(lines, string.rep('─', #title + 4))
  table.insert(lines, '')

  -- Items
  for i, item in ipairs(items) do
    local text = item.text or tostring(item.value or item)
    table.insert(lines, string.format('  %s', text))
    if current_line == 0 then
      current_line = #lines - 1 -- 0-indexed
    end
  end

  -- Help text
  if #help_text > 0 then
    table.insert(lines, '')
    table.insert(lines, 'Help:')
    for _, help in ipairs(help_text) do
      table.insert(lines, '  ' .. help)
    end
  end

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false

  -- Calculate dimensions
  local max_width = 0
  for _, line in ipairs(lines) do
    max_width = math.max(max_width, #line)
  end

  local width = math.min(math.max(max_width + 4, 50), math.floor(vim.o.columns * 0.8))
  local height = math.min(#lines + 2, math.floor(vim.o.lines * 0.8))

  -- Create window
  local win_opts = {
    relative = 'editor',
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    style = 'minimal',
    border = 'rounded',
    title = ' ' .. title .. ' ',
    title_pos = 'center',
  }

  local winid = vim.api.nvim_open_win(bufnr, true, win_opts)

  -- Set cursor to first item
  local item_start_line = 4 -- After title and separator
  if item_start_line < vim.api.nvim_buf_line_count(bufnr) then
    vim.api.nvim_win_set_cursor(winid, { item_start_line + 1, 2 }) -- 1-indexed, with indent
    current_line = 0 -- Index in items array
  end

  -- Navigation functions
  local function move_cursor(direction)
    local current_pos = vim.api.nvim_win_get_cursor(winid)
    local line_num = current_pos[1]

    local new_line = line_num
    local new_current_line = current_line

    if direction == 'down' and current_line < #items - 1 then
      new_line = line_num + 1
      new_current_line = current_line + 1
    elseif direction == 'up' and current_line > 0 then
      new_line = line_num - 1
      new_current_line = current_line - 1
    end

    if new_line ~= line_num then
      vim.api.nvim_win_set_cursor(winid, { new_line, 2 })
      current_line = new_current_line
    end
  end

  local function select_item()
    if current_line >= 0 and current_line < #items then
      local selected_item = items[current_line + 1]
      vim.api.nvim_win_close(winid, true)
      on_select(selected_item)
    end
  end

  local function delete_item()
    if on_delete and current_line >= 0 and current_line < #items then
      local selected_item = items[current_line + 1]
      vim.api.nvim_win_close(winid, true)
      on_delete(selected_item)
    end
  end

  local function close_picker()
    vim.api.nvim_win_close(winid, true)
  end

  -- Set up keymaps
  local keymap_handlers = {
    ['select'] = select_item,
    ['close'] = close_picker,
    ['delete'] = delete_item,
    ['up'] = function()
      move_cursor('up')
    end,
    ['down'] = function()
      move_cursor('down')
    end,
  }

  for key, action in pairs(keymaps) do
    local handler = keymap_handlers[action]
    if handler then
      vim.keymap.set('n', key, handler, { buffer = bufnr, silent = true })
    end
  end

  -- Default keymaps if not overridden
  local default_keymaps = {
    ['<CR>'] = 'select',
    ['<Esc>'] = 'close',
    ['q'] = 'close',
    ['j'] = 'down',
    ['k'] = 'up',
    ['<Down>'] = 'down',
    ['<Up>'] = 'up',
  }

  for key, action in pairs(default_keymaps) do
    if not keymaps[key] and keymap_handlers[action] then
      vim.keymap.set('n', key, keymap_handlers[action], { buffer = bufnr, silent = true })
    end
  end

  -- Add delete keymap if delete handler exists
  if on_delete then
    vim.keymap.set('n', 'd', delete_item, { buffer = bufnr, silent = true })
  end
end

---Create and show an interactive question popup
---@param question string The question to ask
---@param options? string[] List of options
---@param callback function Callback with user response (response_text, cancelled)
function Popup.ask_question(question, options, callback)
  vim.schedule(function()
    question = question or 'No question provided'
    options = options or {}

    local width, height, content_width = calculate_dimensions({})
    local popup_lines, highlights = build_content(question, options, content_width)

    width, height = calculate_dimensions(popup_lines)

    local _, input_buf, popup_win, input_win = create_windows(popup_lines, highlights, width, height)

    apply_fade_in(popup_win, input_win)

    local input_line = vim.api.nvim_buf_get_lines(input_buf, 0, 1, false)[1] or ''
    vim.api.nvim_win_set_cursor(input_win, { 1, #input_line })
    vim.wo[input_win].cursorline = false

    vim.cmd('startinsert')

    setup_key_mappings(input_buf, input_win, options, function(response)
      process_response(response, options, popup_win, input_win, input_buf, callback)
    end)

    vim.defer_fn(function()
      if vim.api.nvim_win_is_valid(input_win) then
        local current_line = vim.api.nvim_buf_get_lines(input_buf, 0, 1, false)[1] or ''
        vim.api.nvim_win_set_cursor(input_win, { 1, #current_line })
      end
    end, 50)
  end)
end

return Popup
