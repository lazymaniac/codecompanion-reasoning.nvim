---@class CodeCompanion.UI.SessionPicker
---Modern split-pane session picker UI for selecting and resuming chat sessions
local SessionPicker = {}

local fmt = string.format
local SessionManager = require('codecompanion._extensions.reasoning.helpers.session_manager')

-- Modern UI Configuration
local UI_CONFIG = {
  colors = {
    -- Main interface colors
    border = 'FloatBorder',
    border_focus = 'DiagnosticInfo',
    title = 'Title',
    subtitle = 'DiagnosticHint',

    -- List pane colors
    list_header = '@text.title',
    list_item = 'Normal',
    list_selected = 'CursorLine',
    list_selected_text = 'CursorLineNr',
    list_meta = '@text.note',
    list_date = '@string.special',
    list_model = '@type',

    -- Preview pane colors
    preview_header = '@text.title',
    preview_label = '@property',
    preview_value = '@string',
    preview_content = 'Normal',
    preview_message_user = '@text.emphasis',
    preview_message_assistant = '@text.strong',
    preview_separator = '@punctuation.delimiter',

    -- Status and accents
    accent_primary = 'DiagnosticInfo',
    accent_secondary = '@constant',
    empty_state = '@text.note',
    action_key = '@keyword',
    action_desc = '@text',
  },

  icons = {
    -- Modern minimalist icons
    session = '●',
    selected = '▸',
    calendar = '',
    model = '',
    messages = '',
    size = '',
    user = '',
    assistant = '🤖',
    empty = '∅',
    preview = '▶',
    separator = '│',
  },

  layout = {
    border_style = 'rounded',
    list_width_ratio = 0.4,
    preview_width_ratio = 0.6,
    max_width_ratio = 0.9,
    max_height_ratio = 0.85,
    min_width = 100,
    min_height = 20,
    padding = 1,
  },

  typography = {
    list_indent = '  ',
    preview_indent = '    ',
    section_spacing = 2,
  },
}

local PREVIEW_MESSAGE_LIMIT = 3
local PREVIEW_LINE_WIDTH = 80
local PREVIEW_LINE_SUFFIX = '...'

local function sanitize_single_line(value)
  if value == nil then
    return ''
  end
  local text_value = tostring(value)
  text_value = text_value:gsub('[\r\n]+', ' ')
  return vim.trim(text_value)
end

local function extract_message_text(message)
  if not message then
    return ''
  end

  local content = message.content
  if type(content) == 'string' then
    return content
  end

  if type(content) == 'table' then
    local parts = {}
    for _, chunk in ipairs(content) do
      if type(chunk) == 'string' then
        table.insert(parts, chunk)
      elseif type(chunk) == 'table' then
        if type(chunk.text) == 'string' then
          table.insert(parts, chunk.text)
        elseif type(chunk.content) == 'string' then
          table.insert(parts, chunk.content)
        end
      end
    end

    if #parts > 0 then
      return table.concat(parts, ' ')
    end

    return ''
  end

  if content == nil then
    return ''
  end

  return tostring(content)
end

local function format_preview_message(prefix, text)
  local sanitized = sanitize_single_line(text)
  local available = PREVIEW_LINE_WIDTH - #prefix - #PREVIEW_LINE_SUFFIX
  if available < 0 then
    available = 0
  end

  local truncated = sanitized:sub(1, available)
  if #sanitized > available then
    truncated = truncated:gsub('%s+$', '')
  end

  truncated = truncated:gsub('[%.%!%?]+$', '')

  if truncated == '' then
    return prefix .. PREVIEW_LINE_SUFFIX
  end

  return prefix .. truncated .. PREVIEW_LINE_SUFFIX
end

-- Format session entry for the list pane (clean, minimal design)
---@param session table Session info object
---@param index number Session index
---@param is_selected boolean Whether this session is selected
---@return string[] lines, table[] highlights
local function format_session_list_entry(session, index, is_selected)
  local lines = {}
  local highlights = {}

  local indent = UI_CONFIG.typography.list_indent
  local prefix = is_selected and UI_CONFIG.icons.selected or UI_CONFIG.icons.session

  -- Main session line shows generated title when available
  local display_title = sanitize_single_line(session.title)
  if display_title == '' then
    local preview_line = session.preview and session.preview:match('^[^\n\r]*')
    display_title = sanitize_single_line(preview_line)
  end
  if display_title == '' then
    display_title = 'Session ' .. tostring(index)
  end

  -- Add favorite icon if session is favorited
  local favorite_indicator = session.is_favorite and '★ ' or ''

  local session_title = fmt('%s%s %s%s', indent, prefix, favorite_indicator, display_title)
  table.insert(lines, session_title)

  -- Highlight prefix
  table.insert(highlights, {
    line = 0,
    col = #indent,
    end_col = #indent + #prefix,
    group = is_selected and UI_CONFIG.colors.accent_primary or UI_CONFIG.colors.list_item,
  })

  -- Highlight session title
  table.insert(highlights, {
    line = 0,
    col = #indent + #prefix + 1,
    end_col = -1,
    group = is_selected and UI_CONFIG.colors.list_selected_text or UI_CONFIG.colors.list_item,
  })

  -- Date line (more compact)
  local created_at = sanitize_single_line(session.created_at)
  local date_display = created_at
  if created_at ~= '' then
    local date_parts = vim.split(created_at, ' ')
    if #date_parts >= 2 then
      date_display = date_parts[1] .. ' ' .. date_parts[2]
    end
  else
    date_display = 'Unknown'
  end
  local date_line = fmt('%s%s %s', indent, UI_CONFIG.icons.calendar, date_display)
  table.insert(lines, date_line)
  table.insert(highlights, {
    line = 1,
    col = 0,
    end_col = -1,
    group = is_selected and UI_CONFIG.colors.list_selected or UI_CONFIG.colors.list_date,
  })

  -- Model and message count (compact)
  local model_name = sanitize_single_line(session.model)
  if model_name == '' then
    model_name = 'Unknown'
  end
  local total_messages = tonumber(session.total_messages) or 0
  local stats_line =
    fmt('%s%s %s  %s %d', indent, UI_CONFIG.icons.model, model_name, UI_CONFIG.icons.messages, total_messages)
  table.insert(lines, stats_line)
  table.insert(highlights, {
    line = 2,
    col = 0,
    end_col = -1,
    group = is_selected and UI_CONFIG.colors.list_selected or UI_CONFIG.colors.list_meta,
  })

  return lines, highlights
end

-- Build detailed preview for the right pane
---@param session table Session info object
---@return string[] lines, table[] highlights
local function build_session_preview(session)
  if not session then
    return { '  No session selected' }, { { line = 0, col = 0, end_col = -1, group = UI_CONFIG.colors.empty_state } }
  end

  local lines = {}
  local highlights = {}
  local line_num = 0

  local function add_line(text, hl_group)
    table.insert(lines, text)
    if hl_group then
      table.insert(highlights, {
        line = line_num,
        col = 0,
        end_col = -1,
        group = hl_group,
      })
    end
    line_num = line_num + 1
  end

  local function add_header(text)
    add_line('', nil)
    add_line('  ' .. text, UI_CONFIG.colors.preview_header)
    add_line('  ' .. string.rep('─', #text), UI_CONFIG.colors.preview_separator)
    line_num = line_num + 1
  end

  local function add_field(label, value, value_hl)
    local display_value = sanitize_single_line(value)
    local field_line = fmt('    %s: %s', label, display_value)
    table.insert(lines, field_line)
    -- Label highlight
    table.insert(highlights, {
      line = line_num,
      col = 4,
      end_col = 4 + #label,
      group = UI_CONFIG.colors.preview_label,
    })
    -- Value highlight
    table.insert(highlights, {
      line = line_num,
      col = 4 + #label + 2,
      end_col = -1,
      group = value_hl or UI_CONFIG.colors.preview_value,
    })
    line_num = line_num + 1
  end

  -- Session Overview
  add_header('Session Overview')
  local overview_title = sanitize_single_line(session.title)
  if overview_title == '' then
    overview_title = 'Untitled'
  end
  local created_display = sanitize_single_line(session.created_at)
  if created_display == '' then
    created_display = 'Unknown'
  end
  local model_display = sanitize_single_line(session.model)
  if model_display == '' then
    model_display = 'Unknown'
  end
  local message_count = tostring(tonumber(session.total_messages) or 0)
  -- Token estimation instead of file size
  local token_estimate = 'Unknown'
  if session.token_estimate then
    token_estimate = tostring(session.token_estimate)
  elseif session.file_size then
    -- Rough estimation: 4 characters per token
    token_estimate = tostring(math.floor(session.file_size / 4))
  end

  add_field('Title', overview_title, UI_CONFIG.colors.list_header)
  add_field('Created', created_display, UI_CONFIG.colors.list_date)
  add_field('Model', model_display, UI_CONFIG.colors.list_model)
  add_field('Messages', message_count, UI_CONFIG.colors.accent_secondary)
  add_field('Est. Tokens', token_estimate, UI_CONFIG.colors.list_meta)

  -- Show tags if present
  if session.tags and #session.tags > 0 then
    add_field('Tags', table.concat(session.tags, ', '), UI_CONFIG.colors.accent_secondary)
  end

  -- Show favorite status
  if session.is_favorite then
    add_field('Favorite', '★', UI_CONFIG.colors.accent_primary)
  end

  -- Session Preview
  local preview_rendered = false
  local load_err
  if session.filename then
    local session_data
    session_data, load_err = SessionManager.load_session(session.filename)

    if session_data and session_data.messages then
      local visible_messages = {}
      for _, message in ipairs(session_data.messages) do
        if message and message.visible ~= false then
          local role = message.role or 'assistant'
          if role == 'user' or role == 'assistant' or role == 'tool' then
            local message_text = extract_message_text(message)
            if sanitize_single_line(message_text) ~= '' then
              table.insert(visible_messages, { role = role, content = message_text })
            end
          end
        end
      end

      if #visible_messages > 0 then
        add_header('Session Preview')
        preview_rendered = true

        local role_labels = {
          user = 'User',
          assistant = 'Assistant',
          system = 'System',
          tool = 'Tool',
        }
        local role_highlights = {
          user = UI_CONFIG.colors.preview_message_user,
          assistant = UI_CONFIG.colors.preview_message_assistant,
          system = UI_CONFIG.colors.preview_label,
          tool = UI_CONFIG.colors.preview_content,
        }

        local max_messages = math.min(#visible_messages, PREVIEW_MESSAGE_LIMIT)
        for index = 1, max_messages do
          local message = visible_messages[index]
          local role = message.role or 'assistant'
          local label = role_labels[role] or (role:gsub('^%l', string.upper))
          local prefix = string.format('%s%s: ', UI_CONFIG.typography.preview_indent, label)

          local rendered_line = format_preview_message(prefix, message.content)
          add_line(rendered_line, role_highlights[role] or UI_CONFIG.colors.preview_content)

          if index < max_messages then
            add_line('', nil)
          end
        end

        if #visible_messages > max_messages then
          local remaining = #visible_messages - max_messages
          local suffix = remaining == 1 and '' or 's'
          add_line(
            string.format('%s… %d more message%s', UI_CONFIG.typography.preview_indent, remaining, suffix),
            UI_CONFIG.colors.preview_content
          )
        end
      end
    end

    if not preview_rendered and load_err then
      add_header('Session Preview')
      add_line(
        string.format('%sUnable to load session preview: %s', UI_CONFIG.typography.preview_indent, load_err),
        UI_CONFIG.colors.preview_value
      )
      preview_rendered = true
    end
  end

  if not preview_rendered and session.preview and session.preview ~= '' then
    add_header('Session Preview')
    preview_rendered = true
    local prefix = UI_CONFIG.typography.preview_indent
      .. (UI_CONFIG.icons.preview ~= '' and (UI_CONFIG.icons.preview .. ' ') or '')
    local rendered_line = format_preview_message(prefix, session.preview)
    add_line(rendered_line, UI_CONFIG.colors.preview_content)
  elseif not preview_rendered then
    add_header('Session Preview')
    add_line(UI_CONFIG.typography.preview_indent .. 'No preview available', UI_CONFIG.colors.preview_content)
  end

  -- Quick Actions
  add_header('Quick Actions')
  add_line('    Enter  Resume session', UI_CONFIG.colors.action_desc)
  add_line('    r      Rename session', UI_CONFIG.colors.action_desc)
  add_line('    R      Regenerate title', UI_CONFIG.colors.action_desc)
  add_line('    d      Delete session', UI_CONFIG.colors.action_desc)
  add_line('    D      Delete all sessions', UI_CONFIG.colors.action_desc)
  add_line('    *      Toggle favorite', UI_CONFIG.colors.action_desc)
  add_line('    f      Search sessions', UI_CONFIG.colors.action_desc)
  add_line('    c      Summarize session', UI_CONFIG.colors.action_desc)
  add_line('    t      Regenerate tags', UI_CONFIG.colors.action_desc)
  add_line('    Esc    Cancel', UI_CONFIG.colors.action_desc)

  return lines, highlights
end

-- Build content for the session list pane (left side)
---@param sessions table[] List of session info objects
---@param selected_index number Currently selected session index
---@return string[] lines, table[] highlights
local function build_session_list_content(sessions, selected_index)
  local lines = {}
  local highlights = {}
  local line_offset = 0
  local selected_row = nil

  -- Header
  table.insert(lines, '')
  table.insert(lines, '  Sessions')
  table.insert(highlights, {
    line = line_offset + 1,
    col = 2,
    end_col = -1,
    group = UI_CONFIG.colors.list_header,
  })
  table.insert(lines, '  ' .. string.rep('─', 15))
  table.insert(highlights, {
    line = line_offset + 2,
    col = 2,
    end_col = -1,
    group = UI_CONFIG.colors.preview_separator,
  })
  table.insert(lines, '')
  line_offset = #lines

  if #sessions == 0 then
    -- Empty state
    table.insert(lines, fmt('  %s No sessions found', UI_CONFIG.icons.empty))
    table.insert(highlights, {
      line = line_offset,
      col = 2,
      end_col = -1,
      group = UI_CONFIG.colors.empty_state,
    })
    table.insert(lines, '  Start a conversation first!')
    table.insert(highlights, {
      line = line_offset + 1,
      col = 2,
      end_col = -1,
      group = UI_CONFIG.colors.empty_state,
    })
  else
    -- Session list
    for i, session in ipairs(sessions) do
      local is_selected = (i == selected_index)
      local entry_start = line_offset
      if is_selected then
        selected_row = entry_start
      end
      local session_lines, session_highlights = format_session_list_entry(session, i, is_selected)

      -- Apply selection background
      if is_selected then
        for j = 0, #session_lines - 1 do
          table.insert(highlights, {
            line = line_offset + j,
            col = 0,
            end_col = -1,
            group = UI_CONFIG.colors.list_selected,
          })
        end
      end

      -- Adjust highlight line numbers to account for offset
      for _, highlight in ipairs(session_highlights) do
        highlight.line = highlight.line + line_offset
        table.insert(highlights, highlight)
      end

      vim.list_extend(lines, session_lines)
      table.insert(lines, '') -- spacing between sessions
      line_offset = #lines
    end
  end

  return lines, highlights, selected_row
end

-- Calculate optimal dimensions for the split-pane layout
---@param sessions table[] List of sessions
---@return table dimensions Layout dimensions
local function calculate_picker_dimensions(sessions)
  local max_width = math.floor(vim.o.columns * UI_CONFIG.layout.max_width_ratio)
  local max_height = math.floor(vim.o.lines * UI_CONFIG.layout.max_height_ratio)

  local total_width = math.max(UI_CONFIG.layout.min_width, math.min(max_width, 120))
  local total_height = math.max(UI_CONFIG.layout.min_height, math.min(max_height, 35))

  local list_width = math.floor(total_width * UI_CONFIG.layout.list_width_ratio) - 1
  local preview_width = total_width - list_width - 1 -- -1 for separator

  return {
    total_width = total_width,
    total_height = total_height,
    list_width = list_width,
    preview_width = preview_width,
    col = math.floor((vim.o.columns - total_width) / 2),
    row = math.floor((vim.o.lines - total_height) / 2),
  }
end

-- Create and apply highlights to a buffer
---@param buf number Buffer handle
---@param highlights table[] Highlight definitions
---@param namespace_suffix string Namespace suffix
local function apply_highlights(buf, highlights, namespace_suffix)
  local ns_id = vim.api.nvim_create_namespace('session_picker_' .. namespace_suffix)
  vim.api.nvim_buf_clear_namespace(buf, ns_id, 0, -1)

  for _, hl in ipairs(highlights) do
    local line_count = vim.api.nvim_buf_line_count(buf)
    if hl.line >= 0 and hl.line < line_count then
      local line_content = vim.api.nvim_buf_get_lines(buf, hl.line, hl.line + 1, false)[1] or ''
      local line_len = #line_content

      if line_len > 0 then
        local start_col = math.max(0, math.min(hl.col, line_len))
        local end_col = hl.end_col == -1 and line_len or math.min(hl.end_col, line_len)

        if start_col <= end_col then -- Allow equal values for single character highlights
          vim.api.nvim_buf_set_extmark(buf, ns_id, hl.line, start_col, {
            end_col = end_col == start_col and start_col + 1 or end_col, -- Ensure minimum width
            hl_group = hl.group,
            strict = false,
          })
        end
      end
    end
  end
end

-- Create the modern split-pane session picker windows
---@param sessions table[] Available sessions
---@param selected_index number Currently selected index
---@param dims table Layout dimensions
---@return table windows Window handles and buffers
local function create_session_picker_windows(sessions, selected_index, dims)
  -- Create list pane (left side)
  local list_buf = vim.api.nvim_create_buf(false, true)
  local list_lines, list_highlights, selected_row = build_session_list_content(sessions, selected_index)
  vim.api.nvim_buf_set_lines(list_buf, 0, -1, false, list_lines)
  vim.bo[list_buf].bufhidden = 'wipe'
  vim.bo[list_buf].filetype = 'codecompanion-sessions-list'
  vim.bo[list_buf].modifiable = false

  apply_highlights(list_buf, list_highlights, 'list')

  local list_win_opts = {
    relative = 'editor',
    width = dims.list_width,
    height = dims.total_height,
    col = dims.col,
    row = dims.row,
    style = 'minimal',
    border = UI_CONFIG.layout.border_style,
    title = ' Sessions ',
    title_pos = 'left',
    zindex = 100,
  }

  local list_win = vim.api.nvim_open_win(list_buf, true, list_win_opts)
  vim.wo[list_win].winhl = 'FloatBorder:' .. UI_CONFIG.colors.border_focus
  vim.wo[list_win].cursorline = false
  if selected_row and selected_row >= 0 then
    pcall(vim.api.nvim_win_set_cursor, list_win, { selected_row + 1, 0 })
  else
    pcall(vim.api.nvim_win_set_cursor, list_win, { 1, 0 })
  end

  -- Create preview pane (right side)
  local preview_buf = vim.api.nvim_create_buf(false, true)
  local selected_session = sessions[selected_index]
  local preview_lines, preview_highlights = build_session_preview(selected_session)
  vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, preview_lines)
  vim.bo[preview_buf].bufhidden = 'wipe'
  vim.bo[preview_buf].filetype = 'codecompanion-sessions-preview'
  vim.bo[preview_buf].modifiable = false

  apply_highlights(preview_buf, preview_highlights, 'preview')

  local preview_win_opts = {
    relative = 'editor',
    width = dims.preview_width,
    height = dims.total_height,
    col = dims.col + dims.list_width + 1,
    row = dims.row,
    style = 'minimal',
    border = UI_CONFIG.layout.border_style,
    title = ' Preview ',
    title_pos = 'left',
    zindex = 100,
  }

  local preview_win = vim.api.nvim_open_win(preview_buf, false, preview_win_opts)
  vim.wo[preview_win].winhl = 'FloatBorder:' .. UI_CONFIG.colors.border

  return {
    list = { buf = list_buf, win = list_win },
    preview = { buf = preview_buf, win = preview_win },
  }
end

-- Set up key mappings for the modern split-pane picker
---@param windows table Window handles
---@param sessions table[] Available sessions
---@param selected_index number Initially selected index
---@param callback function Selection callback
local function setup_picker_mappings(windows, sessions, selected_index, callback)
  local current_selection = selected_index
  local list_buf = windows.list.buf
  local preview_buf = windows.preview.buf
  local list_win = windows.list.win

  local function update_display()
    -- Update list pane
    local list_lines, list_highlights, selected_row = build_session_list_content(sessions, current_selection)
    vim.bo[list_buf].modifiable = true
    vim.api.nvim_buf_set_lines(list_buf, 0, -1, false, list_lines)
    vim.bo[list_buf].modifiable = false
    apply_highlights(list_buf, list_highlights, 'list')
    if selected_row and selected_row >= 0 then
      pcall(vim.api.nvim_win_set_cursor, list_win, { selected_row + 1, 0 })
    end

    -- Update preview pane
    local selected_session = sessions[current_selection]
    local preview_lines, preview_highlights = build_session_preview(selected_session)
    vim.bo[preview_buf].modifiable = true
    vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, preview_lines)
    vim.bo[preview_buf].modifiable = false
    apply_highlights(preview_buf, preview_highlights, 'preview')
  end

  -- Navigation keys (only for list buffer)
  local navigation_keys = {
    { 'n', '<Up>' },
    { 'n', 'k' },
    { 'n', '<Down>' },
    { 'n', 'j' },
  }

  for _, key_config in ipairs(navigation_keys) do
    local mode, key = key_config[1], key_config[2]
    local is_up = key:match('Up') or key == 'k'

    vim.api.nvim_buf_set_keymap(list_buf, mode, key, '', {
      noremap = true,
      silent = true,
      callback = function()
        if #sessions == 0 then
          return
        end

        if is_up then
          current_selection = current_selection > 1 and current_selection - 1 or #sessions
        else
          current_selection = current_selection < #sessions and current_selection + 1 or 1
        end
        update_display()
      end,
    })
  end

  -- Selection keys
  local select_keys = { { 'n', '<CR>' }, { 'n', '<Space>' } }
  for _, key_config in ipairs(select_keys) do
    vim.api.nvim_buf_set_keymap(list_buf, key_config[1], key_config[2], '', {
      noremap = true,
      silent = true,
      callback = function()
        if #sessions > 0 and current_selection >= 1 and current_selection <= #sessions then
          callback('select', sessions[current_selection])
        else
          callback('cancel')
        end
      end,
    })
  end

  -- Delete key
  vim.api.nvim_buf_set_keymap(list_buf, 'n', 'd', '', {
    noremap = true,
    silent = true,
    callback = function()
      if #sessions > 0 and current_selection >= 1 and current_selection <= #sessions then
        callback('delete', sessions[current_selection])
      end
    end,
  })

  -- Rename key
  vim.api.nvim_buf_set_keymap(list_buf, 'n', 'r', '', {
    noremap = true,
    silent = true,
    callback = function()
      if #sessions > 0 and current_selection >= 1 and current_selection <= #sessions then
        callback('rename', sessions[current_selection])
      end
    end,
  })

  -- Regenerate title key
  vim.api.nvim_buf_set_keymap(list_buf, 'n', 'R', '', {
    noremap = true,
    silent = true,
    callback = function()
      if #sessions > 0 and current_selection >= 1 and current_selection <= #sessions then
        callback('regenerate_title', sessions[current_selection])
      end
    end,
  })

  -- Delete all key
  vim.api.nvim_buf_set_keymap(list_buf, 'n', 'D', '', {
    noremap = true,
    silent = true,
    callback = function()
      if #sessions > 0 then
        callback('delete_all', nil)
      end
    end,
  })

  -- Mark as favorite key
  vim.api.nvim_buf_set_keymap(list_buf, 'n', '*', '', {
    noremap = true,
    silent = true,
    callback = function()
      if #sessions > 0 and current_selection >= 1 and current_selection <= #sessions then
        callback('toggle_favorite', sessions[current_selection])
      end
    end,
  })

  -- Search entries key
  vim.api.nvim_buf_set_keymap(list_buf, 'n', 'f', '', {
    noremap = true,
    silent = true,
    callback = function()
      callback('search', nil)
    end,
  })

  -- Summarize entry key
  vim.api.nvim_buf_set_keymap(list_buf, 'n', 'c', '', {
    noremap = true,
    silent = true,
    callback = function()
      if #sessions > 0 and current_selection >= 1 and current_selection <= #sessions then
        callback('summarize', sessions[current_selection])
      end
    end,
  })

  -- Regenerate tags key
  vim.api.nvim_buf_set_keymap(list_buf, 'n', 't', '', {
    noremap = true,
    silent = true,
    callback = function()
      if #sessions > 0 and current_selection >= 1 and current_selection <= #sessions then
        callback('regenerate_tags', sessions[current_selection])
      end
    end,
  })

  -- Cancel keys
  local cancel_keys = { { 'n', '<Esc>' }, { 'n', 'q' } }
  for _, key_config in ipairs(cancel_keys) do
    vim.api.nvim_buf_set_keymap(list_buf, key_config[1], key_config[2], '', {
      noremap = true,
      silent = true,
      callback = function()
        callback('cancel')
      end,
    })
  end
end

-- Main API function to show the modern split-pane session picker
---@param callback function Callback function (action, session_or_nil)
function SessionPicker.show_session_picker(callback)
  vim.schedule(function()
    local sessions = SessionManager.list_sessions()
    local selected_index = math.min(1, #sessions)

    local dims = calculate_picker_dimensions(sessions)
    local windows = create_session_picker_windows(sessions, selected_index, dims)

    -- Set up auto-close function
    local function close_picker()
      for _, win_data in pairs(windows) do
        if vim.api.nvim_win_is_valid(win_data.win) then
          vim.api.nvim_win_close(win_data.win, true)
        end
      end
    end

    local function picker_callback(action, session)
      if action == 'select' and session then
        close_picker()
        callback('select', session)
      elseif action == 'delete' and session then
        close_picker()
        -- Modern confirmation dialog
        local confirm_msg = fmt('Delete session from %s?', session.created_at or 'unknown date')
        local choice = vim.fn.confirm(confirm_msg, '&Delete\n&Cancel', 2, 'Question')
        if choice == 1 then
          local success, err = SessionManager.delete_session(session.filename)
          if success then
            vim.notify('✓ Session deleted', vim.log.levels.INFO)
          else
            vim.notify('✗ Failed to delete session: ' .. err, vim.log.levels.ERROR)
          end
        end
        -- Re-show picker after deletion attempt
        SessionPicker.show_session_picker(callback)
      elseif action == 'rename' and session then
        close_picker()
        SessionPicker._handle_rename(session, callback)
      elseif action == 'regenerate_title' and session then
        close_picker()
        SessionPicker._handle_regenerate_title(session, callback)
      elseif action == 'delete_all' then
        close_picker()
        SessionPicker._handle_delete_all(callback)
      elseif action == 'toggle_favorite' and session then
        close_picker()
        SessionPicker._handle_toggle_favorite(session, callback)
      elseif action == 'search' then
        close_picker()
        SessionPicker._handle_search(callback)
      elseif action == 'summarize' and session then
        close_picker()
        SessionPicker._handle_summarize(session, callback)
      elseif action == 'regenerate_tags' and session then
        close_picker()
        SessionPicker._handle_regenerate_tags(session, callback)
      else
        close_picker()
        callback('cancel')
      end
    end

    setup_picker_mappings(windows, sessions, selected_index, picker_callback)

    -- Focus the list window
    vim.api.nvim_set_current_win(windows.list.win)
  end)
end

-- Handler function for renaming sessions
---@param session table Session to rename
---@param callback function Main picker callback
function SessionPicker._handle_rename(session, callback)
  local current_title = session.title or 'Untitled'

  vim.ui.input({
    prompt = 'New title: ',
    default = current_title,
  }, function(new_title)
    if new_title and new_title ~= '' and new_title ~= current_title then
      -- Load the session data
      local session_data, err = SessionManager.load_session(session.filename)
      if not session_data then
        vim.notify(fmt('Failed to load session: %s', err or 'unknown error'), vim.log.levels.ERROR)
        SessionPicker.show_session_picker(callback)
        return
      end

      -- Update the title in the session data
      session_data.title = new_title
      session_data.updated_at = os.time()

      -- Save the updated session
      local success, save_err = SessionManager.save_session_data(session_data, session.filename)
      if success then
        vim.notify(fmt('✓ Renamed to "%s"', new_title), vim.log.levels.INFO)
      else
        vim.notify(fmt('✗ Failed to rename: %s', save_err or 'unknown error'), vim.log.levels.ERROR)
      end
    end

    -- Re-show picker regardless of whether rename was successful
    SessionPicker.show_session_picker(callback)
  end)
end

-- Handler function for regenerating session titles
---@param session table Session to regenerate title for
---@param callback function Main picker callback
function SessionPicker._handle_regenerate_title(session, callback)
  vim.notify('Regenerating title...', vim.log.levels.INFO)

  -- Load the session data to create a mock chat object
  local session_data, err = SessionManager.load_session(session.filename)
  if not session_data then
    vim.notify(fmt('Failed to load session: %s', err or 'unknown error'), vim.log.levels.ERROR)
    SessionPicker.show_session_picker(callback)
    return
  end

  vim.notify('Session Data: ' .. vim.inspect(session_data))

  -- Create mock chat object for title generation
  local mock_chat = {
    messages = session_data.messages or {},
    adapter = session_data.config and session_data.config.adapter,
    opts = { title = session_data.title },
    settings = session_data.config,
  }

  local TitleGenerator = require('codecompanion._extensions.reasoning.helpers.session_title_generator')
  local title_gen = TitleGenerator.new()

  title_gen:generate(mock_chat, function(new_title)
    if new_title and new_title ~= '' and new_title ~= 'Generating title...' and new_title ~= 'Refreshing title...' then
      session_data.title = new_title
      session_data.updated_at = os.time()

      local success, save_err = SessionManager.save_session_data(session_data, session.filename)
      if success then
        vim.notify(fmt('✓ Title regenerated: "%s"', new_title), vim.log.levels.INFO)
      else
        vim.notify(fmt('✗ Failed to save new title: %s', save_err or 'unknown error'), vim.log.levels.ERROR)
      end
    else
      vim.notify('✗ Failed to generate new title', vim.log.levels.ERROR)
    end

    -- Re-show picker
    SessionPicker.show_session_picker(callback)
  end) -- true indicates this is a refresh
end

-- Handler function for deleting all sessions
---@param callback function Main picker callback
function SessionPicker._handle_delete_all(callback)
  local sessions = SessionManager.list_sessions()

  if #sessions == 0 then
    vim.notify('No sessions to delete', vim.log.levels.INFO)
    SessionPicker.show_session_picker(callback)
    return
  end

  local confirm_msg = fmt('Delete all %d sessions? This cannot be undone.', #sessions)
  local choice = vim.fn.confirm(confirm_msg, '&Delete All\n&Cancel', 2, 'Question')

  if choice == 1 then
    local deleted_count = 0
    local failed_count = 0

    for _, session in ipairs(sessions) do
      local success, err = SessionManager.delete_session(session.filename)
      if success then
        deleted_count = deleted_count + 1
      else
        failed_count = failed_count + 1
        vim.notify(fmt('Failed to delete %s: %s', session.filename, err), vim.log.levels.ERROR)
      end
    end

    if deleted_count > 0 then
      vim.notify(fmt('✓ Deleted %d sessions', deleted_count), vim.log.levels.INFO)
    end

    if failed_count > 0 then
      vim.notify(fmt('✗ Failed to delete %d sessions', failed_count), vim.log.levels.ERROR)
    end
  end

  -- Re-show picker
  SessionPicker.show_session_picker(callback)
end

-- Handler function for toggling favorite status
---@param session table Session to toggle favorite
---@param callback function Main picker callback
function SessionPicker._handle_toggle_favorite(session, callback)
  local session_data, err = SessionManager.load_session(session.filename)
  if not session_data then
    vim.notify(fmt('Failed to load session: %s', err or 'unknown error'), vim.log.levels.ERROR)
    SessionPicker.show_session_picker(callback)
    return
  end

  -- Initialize metadata if not present
  session_data.metadata = session_data.metadata or {}
  local is_favorite = session_data.metadata.favorite or false
  session_data.metadata.favorite = not is_favorite
  session_data.updated_at = os.time()

  local success, save_err = SessionManager.save_session_data(session_data, session.filename)
  if success then
    local status = session_data.metadata.favorite and 'added to' or 'removed from'
    vim.notify(fmt('✓ Session %s favorites', status), vim.log.levels.INFO)
  else
    vim.notify(fmt('✗ Failed to update favorite: %s', save_err or 'unknown error'), vim.log.levels.ERROR)
  end

  -- Re-show picker
  SessionPicker.show_session_picker(callback)
end

-- Handler function for search functionality
---@param callback function Main picker callback
function SessionPicker._handle_search(callback)
  vim.ui.input({
    prompt = 'Search sessions: ',
  }, function(query)
    if query and query ~= '' then
      SessionPicker.show_filtered_sessions(query, callback)
    else
      SessionPicker.show_session_picker(callback)
    end
  end)
end

-- Handler function for summarizing sessions
---@param session table Session to summarize
---@param callback function Main picker callback
function SessionPicker._handle_summarize(session, callback)
  vim.notify('Summarizing session...', vim.log.levels.INFO)

  local session_data, err = SessionManager.load_session(session.filename)
  if not session_data then
    vim.notify(fmt('Failed to load session: %s', err or 'unknown error'), vim.log.levels.ERROR)
    SessionPicker.show_session_picker(callback)
    return
  end

  local SessionOptimizer = require('codecompanion._extensions.reasoning.helpers.session_optimizer')
  local optimizer = SessionOptimizer.new()

  optimizer:compact_session(session_data, function(compacted_data, compact_err)
    if compacted_data and not compact_err then
      local success, save_err = SessionManager.save_session_data(compacted_data, session.filename)
      if success then
        vim.notify('✓ Session summarized', vim.log.levels.INFO)
      else
        vim.notify(fmt('✗ Failed to save summary: %s', save_err or 'unknown error'), vim.log.levels.ERROR)
      end
    else
      vim.notify(fmt('✗ Failed to summarize: %s', compact_err or 'unknown error'), vim.log.levels.ERROR)
    end

    -- Re-show picker
    SessionPicker.show_session_picker(callback)
  end)
end

-- Handler function for regenerating session tags
---@param session table Session to regenerate tags for
---@param callback function Main picker callback
function SessionPicker._handle_regenerate_tags(session, callback)
  vim.notify('Regenerating tags...', vim.log.levels.INFO)

  local session_data, err = SessionManager.load_session(session.filename)
  if not session_data then
    vim.notify(fmt('Failed to load session: %s', err or 'unknown error'), vim.log.levels.ERROR)
    SessionPicker.show_session_picker(callback)
    return
  end

  SessionPicker._generate_session_tags(session_data, function(tags)
    if tags and #tags > 0 then
      session_data.metadata = session_data.metadata or {}
      session_data.metadata.tags = tags
      session_data.updated_at = os.time()

      local success, save_err = SessionManager.save_session_data(session_data, session.filename)
      if success then
        vim.notify(fmt('✓ Tags regenerated: %s', table.concat(tags, ', ')), vim.log.levels.INFO)
      else
        vim.notify(fmt('✗ Failed to save tags: %s', save_err or 'unknown error'), vim.log.levels.ERROR)
      end
    else
      vim.notify('✗ Failed to generate tags', vim.log.levels.ERROR)
    end

    -- Re-show picker
    SessionPicker.show_session_picker(callback)
  end)
end

-- Function to show filtered sessions based on search query
---@param query string Search query
---@param callback function Main picker callback
function SessionPicker.show_filtered_sessions(query, callback)
  vim.schedule(function()
    local all_sessions = SessionManager.list_sessions()
    local filtered_sessions = {}

    -- Normalize query for case-insensitive search
    local normalized_query = query:lower()

    for _, session in ipairs(all_sessions) do
      local matches = false

      -- Search in title
      if session.title and session.title:lower():find(normalized_query, 1, true) then
        matches = true
      end

      -- Search in preview/content
      if not matches and session.preview and session.preview:lower():find(normalized_query, 1, true) then
        matches = true
      end

      -- Search in tags if present
      if not matches then
        local session_data = SessionManager.load_session(session.filename)
        if session_data and session_data.metadata and session_data.metadata.tags then
          for _, tag in ipairs(session_data.metadata.tags) do
            if tag:lower():find(normalized_query, 1, true) then
              matches = true
              break
            end
          end
        end
      end

      if matches then
        table.insert(filtered_sessions, session)
      end
    end

    local dims = calculate_picker_dimensions(filtered_sessions)
    local windows = create_session_picker_windows(filtered_sessions, 1, dims)

    -- Set up auto-close function
    local function close_picker()
      for _, win_data in pairs(windows) do
        if vim.api.nvim_win_is_valid(win_data.win) then
          vim.api.nvim_win_close(win_data.win, true)
        end
      end
    end

    local function picker_callback(action, session)
      if action == 'select' and session then
        close_picker()
        callback('select', session)
      else
        close_picker()
        if action == 'cancel' then
          -- Return to main picker instead of canceling entirely
          SessionPicker.show_session_picker(callback)
        end
      end
    end

    -- Show filtered results count
    if #filtered_sessions == 0 then
      vim.notify(fmt('No sessions found matching "%s"', query), vim.log.levels.INFO)
      SessionPicker.show_session_picker(callback)
      return
    else
      vim.notify(fmt('Found %d sessions matching "%s"', #filtered_sessions, query), vim.log.levels.INFO)
    end

    setup_picker_mappings(windows, filtered_sessions, 1, picker_callback)
    vim.api.nvim_set_current_win(windows.list.win)
  end)
end

-- Function to generate tags for a session using LLM
---@param session_data table Session data
---@param callback function Callback to receive tags array
function SessionPicker._generate_session_tags(session_data, callback)
  if not session_data.messages or #session_data.messages == 0 then
    if callback then
      callback({})
    end
    return
  end

  -- Create a conversation context similar to title generation
  local relevant_messages = vim.tbl_filter(function(msg)
    local has_content = msg.content and type(msg.content) == 'string' and vim.trim(msg.content) ~= ''
    local is_relevant_role = msg.role == 'user' or msg.role == 'assistant'
    local not_tagged = not (msg.opts and (msg.opts.tag or msg.opts.reference or msg.opts.context_id))
    return has_content and is_relevant_role and not_tagged
  end, session_data.messages)

  if #relevant_messages == 0 then
    if callback then
      callback({})
    end
    return
  end

  local conversation_lines = {}
  for i = 1, math.min(10, #relevant_messages) do -- Limit to first 10 messages for tagging
    local message = relevant_messages[i]
    local role_prefix = message.role == 'user' and 'User' or 'Assistant'
    -- Ensure content is a string before trimming
    local content = type(message.content) == 'string' and vim.trim(message.content) or ''

    if #content > 500 then
      content = content:sub(1, 500) .. ' [truncated]'
    end

    table.insert(conversation_lines, role_prefix .. ': ' .. content)
  end

  local conversation_context = table.concat(conversation_lines, '\n')

  local prompt = fmt(
    [[Generate 3-5 relevant tags for this chat conversation. Tags should be:
- Single words or short phrases (2-3 words max)
- Descriptive of the main topics, technologies, or themes
- Useful for categorization and search
- Lowercase with no special characters

Examples of good tags: "python", "debugging", "web development", "code review", "api design"

Conversation:
%s

Respond with only a comma-separated list of tags, nothing else.

Tags:]],
    conversation_context
  )

  SessionPicker._make_llm_request(session_data, prompt, function(response)
    if response and response ~= '' then
      -- Parse the response into tags
      local tags = {}
      for tag in response:gmatch('[^,]+') do
        tag = vim.trim(tag):lower()
        if tag ~= '' and #tag <= 20 then -- Reasonable tag length limit
          table.insert(tags, tag)
        end
      end

      -- Limit to 5 tags maximum
      if #tags > 5 then
        tags = vim.list_slice(tags, 1, 5)
      end

      if callback then
        callback(tags)
      end
    else
      if callback then
        callback({})
      end
    end
  end)
end

-- Function to make LLM requests for tags and other operations
---@param session_data table Session data for context
---@param prompt string Prompt to send to LLM
---@param callback function Callback to receive response
function SessionPicker._make_llm_request(session_data, prompt, callback)
  local client_ok, client = pcall(require, 'codecompanion.http')
  local schema_ok, schema = pcall(require, 'codecompanion.schema')
  local adapters_ok, adapters = pcall(require, 'codecompanion.adapters')

  if not client_ok or not schema_ok or not adapters_ok then
    if callback then
      callback(nil)
    end
    return
  end

  local function resolve_adapter(value)
    if not value then
      return nil
    end
    if type(value) == 'table' then
      return value
    end
    return adapters.resolve(value)
  end

  local adapter = resolve_adapter(session_data.config and session_data.config.adapter)
  if not adapter then
    if callback then
      callback(nil)
    end
    return
  end

  local settings = session_data.config and vim.deepcopy(session_data.config) or {}
  settings = schema.get_default(adapter, settings)
  settings = vim.deepcopy(adapter:map_schema_to_params(settings))
  settings.opts = settings.opts or {}
  settings.opts.stream = false

  local payload = {
    messages = adapter:map_roles({
      { role = 'user', content = prompt },
    }),
  }

  client.new({ adapter = settings }):request(payload, {
    callback = function(err, data, _adapter)
      if err and err.stderr ~= '{}' then
        if callback then
          callback(nil)
        end
        return
      end

      if data and _adapter and _adapter.handlers and _adapter.handlers.chat_output then
        local result = _adapter.handlers.chat_output(_adapter, data)
        if result and result.status == 'success' then
          local response = vim.trim(result.output.content or '')
          if callback then
            callback(response)
          end
          return
        end
      end

      if callback then
        callback(nil)
      end
    end,
  }, {
    silent = true,
  })
end

return SessionPicker
