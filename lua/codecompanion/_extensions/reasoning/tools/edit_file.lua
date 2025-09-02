local fmt = string.format

---Safely split a string into lines without losing empty trailing lines
---@param s string
---@return string[]
local function split_lines(s)
  if s == nil or s == '' then
    return {}
  end
  -- Use plain split; keepempty = true to preserve blanks
  local parts = vim.split(s, '\n', { plain = true })
  return parts
end

---Join lines with newlines (no trailing newline added implicitly)
---@param lines string[]
---@return string
local function join_lines(lines)
  if not lines or #lines == 0 then
    return ''
  end
  return table.concat(lines, '\n')
end

---Compute the updated file content given a line range replacement
---@param original string[] existing file lines
---@param start_line integer 1-based inclusive, or special insert rules (-1 for append)
---@param end_line integer 1-based inclusive, or special insert rules (-1 for append, start-1 for insert)
---@param new_content string new block text
---@return boolean ok, string[]|string updated_lines_or_error
local function apply_edit(original, start_line, end_line, new_content)
  -- Input validation
  if type(original) ~= 'table' then
    return false, 'original must be a table of strings'
  end
  if type(start_line) ~= 'number' or type(end_line) ~= 'number' then
    return false, 'start_line and end_line must be numbers'
  end
  if type(new_content) ~= 'string' then
    return false, 'new_content must be a string'
  end

  -- Convert to integers and validate
  start_line = math.floor(start_line)
  end_line = math.floor(end_line)

  local line_count = #original

  -- Handle special cases
  if start_line == -1 and end_line == -1 then
    -- Append at EOF - always valid
    local result = {}
    for i = 1, line_count do
      result[i] = original[i]
    end
    local new_lines = split_lines(new_content)
    for _, line in ipairs(new_lines) do
      table.insert(result, line)
    end
    return true, result
  end

  if end_line == start_line - 1 then
    -- Insert before start_line
    if start_line < 1 or start_line > line_count + 1 then
      return false, fmt('Invalid insert position: line %d (valid range: 1-%d)', start_line, line_count + 1)
    end

    local result = {}
    -- Copy lines before insertion point
    for i = 1, start_line - 1 do
      result[i] = original[i]
    end

    -- Insert new content
    local new_lines = split_lines(new_content)
    local pos = start_line - 1
    for _, line in ipairs(new_lines) do
      pos = pos + 1
      result[pos] = line
    end

    -- Copy lines after insertion point
    for i = start_line, line_count do
      pos = pos + 1
      result[pos] = original[i]
    end

    return true, result
  end

  -- Replace range - validate bounds
  if start_line < 1 or end_line < 1 then
    return false, fmt('Invalid range: lines must be >= 1, got start=%d, end=%d', start_line, end_line)
  end

  if start_line > end_line then
    return false, fmt('Invalid range: start_line (%d) > end_line (%d)', start_line, end_line)
  end

  if end_line > line_count then
    if line_count == 0 then
      return false, fmt('Cannot replace lines %d-%d in empty file', start_line, end_line)
    else
      return false, fmt('Invalid range: end_line %d exceeds file length %d', end_line, line_count)
    end
  end

  -- Build result efficiently using table.move when possible
  local result = {}

  -- Copy lines before replacement
  if start_line > 1 then
    for i = 1, start_line - 1 do
      result[i] = original[i]
    end
  end

  -- Insert new content
  local new_lines = split_lines(new_content)
  local pos = start_line - 1
  for _, line in ipairs(new_lines) do
    pos = pos + 1
    result[pos] = line
  end

  -- Copy lines after replacement
  if end_line < line_count then
    for i = end_line + 1, line_count do
      pos = pos + 1
      result[pos] = original[i]
    end
  end

  return true, result
end

---Open a diff preview using the target window (or a reasonable fallback)
---@param opts table|nil Optional opts { target_win: integer?, target_buf: integer? }
local function open_diff_preview(path, updated_lines, on_decision, opts)
  vim.schedule(function()
    -- Try to reuse a reasonable window: current non-floating window
    local function pick_window()
      -- Use a window showing the desired buffer if available
      if opts and opts.target_buf and vim.api.nvim_buf_is_valid(opts.target_buf) then
        local wid = vim.fn.bufwinid(opts.target_buf)
        if wid ~= -1 and vim.api.nvim_win_is_valid(wid) then
          local cfg = vim.api.nvim_win_get_config(wid)
          if not cfg or cfg.relative == '' then
            return wid
          end
        end
      end

      -- Use provided target window if valid and not floating
      local target = opts and opts.target_win
      if target and vim.api.nvim_win_is_valid(target) then
        local cfg = vim.api.nvim_win_get_config(target)
        if not cfg or cfg.relative == '' then
          return target
        end
      end

      local cur = vim.api.nvim_get_current_win()
      local cfg = vim.api.nvim_win_get_config(cur)
      if not cfg or cfg.relative == '' then
        return cur
      end
      local wins = vim.api.nvim_tabpage_list_wins(0)
      for _, w in ipairs(wins) do
        local c = vim.api.nvim_win_get_config(w)
        if not c or c.relative == '' then
          return w
        end
      end
      return cur
    end

    local win = pick_window()
    if not vim.api.nvim_win_is_valid(win) then
      win = vim.api.nvim_get_current_win()
    end

    -- Load the original file to capture its content and restore later
    vim.api.nvim_set_current_win(win)
    vim.cmd('edit ' .. vim.fn.fnameescape(path))
    local file_buf = vim.api.nvim_get_current_buf()

    -- Prepare unified diff text
    local original_lines = vim.api.nvim_buf_get_lines(file_buf, 0, -1, false)
    local old_text = table.concat(original_lines, '\n') .. '\n'
    local new_text = table.concat(updated_lines, '\n') .. '\n'
    -- Use a large context so the unified diff shows the full file
    local full_ctx = math.max(#original_lines, #updated_lines)
    local diff = vim.diff(old_text, new_text, {
      result_type = 'unified',
      algorithm = 'myers',
      ctxlen = full_ctx,
      linematch = true,
    }) or ''

    -- Prepend headers for better readability
    local header = fmt('--- a/%s\n+++ b/%s\n', path, path)
    local diff_text = header .. diff
    local diff_lines = vim.split(diff_text, '\n', { trimempty = true })

    -- Create a scratch buffer to show unified diff in the same window
    local diff_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(win, diff_buf)
    vim.api.nvim_buf_set_lines(diff_buf, 0, -1, false, diff_lines)
    vim.bo[diff_buf].buftype = 'nofile'
    vim.bo[diff_buf].bufhidden = 'wipe'
    vim.bo[diff_buf].swapfile = false
    vim.bo[diff_buf].modifiable = false
    vim.bo[diff_buf].filetype = 'diff'
    pcall(vim.api.nvim_set_option_value, 'conceallevel', 0, { win = win })

    -- Add virtual text hints at each hunk (no global top hint)
    local ns = vim.api.nvim_create_namespace('CodeCompanionEditDiff')
    local first_hunk_lnum ---@type integer|nil
    for i, line in ipairs(diff_lines) do
      if line:find('^@@') then
        pcall(vim.api.nvim_buf_set_extmark, diff_buf, ns, i - 1, 0, {
          virt_text = {
            { '  [a] Accept  [q] Reject', 'Comment' },
          },
          virt_text_pos = 'right_align',
          priority = 100,
        })
        if not first_hunk_lnum then
          first_hunk_lnum = i
        end
      end
    end

    -- Jump to the start of the diff and scroll it into view
    -- Prefer the first hunk header if present; otherwise go to the top
    local target_line = first_hunk_lnum or 1
    pcall(vim.api.nvim_win_set_cursor, win, { target_line, 0 })
    pcall(vim.api.nvim_win_call, win, function()
      pcall(vim.cmd, 'normal! zt')
    end)

    local function cleanup_and_restore()
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_set_current_win(win)
        vim.cmd('edit ' .. vim.fn.fnameescape(path))
      end
      if vim.api.nvim_buf_is_valid(diff_buf) then
        pcall(vim.api.nvim_buf_delete, diff_buf, { force = true })
      end
    end

    local function accept()
      -- Apply changes to the actual buffer and save via :write to trigger autocmds
      local saved = false
      if file_buf and vim.api.nvim_buf_is_valid(file_buf) then
        pcall(vim.api.nvim_buf_set_option, file_buf, 'modifiable', true)
        local ok_set = pcall(vim.api.nvim_buf_set_lines, file_buf, 0, -1, false, updated_lines)
        if ok_set then
          pcall(vim.api.nvim_buf_call, file_buf, function()
            pcall(vim.cmd, 'silent keepalt write')
          end)
          saved = true
        end
      end

      if not saved then
        -- Fallback to direct file write if buffer operations fail
        pcall(vim.fn.writefile, updated_lines, path)
      end

      cleanup_and_restore()
      on_decision(true)
    end

    local function reject()
      cleanup_and_restore()
      on_decision(false)
    end

    local mapopts = { noremap = true, silent = true, nowait = true, buffer = diff_buf }
    vim.keymap.set('n', 'a', accept, mapopts)
    vim.keymap.set('n', 'A', accept, mapopts)
    vim.keymap.set('n', 'q', reject, mapopts)
    vim.keymap.set('n', '<Esc>', reject, mapopts)

    vim.schedule(function()
      pcall(vim.api.nvim_echo, {
        { 'Unified diff: ', 'Comment' },
        { 'a', 'Identifier' },
        { ' Accept  ', 'Comment' },
        { 'q', 'Identifier' },
        { ' Reject', 'Comment' },
      }, false, {})
    end)
  end)
end

---@class CodeCompanion.Tool.EditFile: CodeCompanion.Tools.Tool
return {
  name = 'edit_file',

  ---Single interactive command: compute new content, open diff, await decision
  cmds = {
    ---@param self CodeCompanion.Tool.EditFile
    ---@param args { path:string, start_line:integer, end_line:integer, new_content:string }
    ---@param input any
    ---@param callback fun(result:{ status:'success'|'error', data:string })
    function(self, args, input, callback)
      local path = args and args.path
      local start_line = args and tonumber(args.start_line)
      local end_line = args and tonumber(args.end_line)
      local new_content = args and (args.new_content or '')

      if type(path) ~= 'string' or path == '' then
        return callback({ status = 'error', data = 'path (string) is required' })
      end
      if type(start_line) ~= 'number' or type(end_line) ~= 'number' then
        return callback({ status = 'error', data = 'start_line and end_line must be integers' })
      end

      local stat = vim.loop.fs_stat(path)
      if not stat then
        return callback({ status = 'error', data = fmt("File not found: '%s'", path) })
      end

      local ok_read, original = pcall(vim.fn.readfile, path)
      if not ok_read or type(original) ~= 'table' then
        return callback({ status = 'error', data = fmt("Failed to read file: '%s'", path) })
      end

      local ok_apply, updated_or_err = apply_edit(original, start_line, end_line, new_content)
      if not ok_apply then
        return callback({ status = 'error', data = updated_or_err })
      end

      local updated = updated_or_err ---@type string[]
      local old_text = join_lines(original)
      local new_text = join_lines(updated)

      if old_text == new_text then
        return callback({ status = 'success', data = fmt('No changes for %s (already up to date)', path) })
      end

      -- Prefer the chat's context window (previous window when chat opened)
      local target_win, target_buf = nil, nil
      pcall(function()
        if self and self.chat and self.chat.buffer_context then
          local ctx = self.chat.buffer_context
          target_buf = ctx.bufnr
          -- Prefer a persistent window id if present
          if ctx.winid and type(ctx.winid) == 'number' then
            target_win = ctx.winid
          elseif ctx.winnr and type(ctx.winnr) == 'number' then
            local wid = vim.fn.win_getid(ctx.winnr)
            if wid and wid ~= 0 then
              target_win = wid
            end
          end
        end
      end)

      open_diff_preview(path, updated, function(applied)
        if applied then
          callback({ status = 'success', data = fmt('Applied edit to %s', path) })
        else
          callback({ status = 'success', data = fmt('Rejected edit for %s', path) })
        end
      end, { target_win = target_win, target_buf = target_buf })
    end,
  },

  schema = {
    type = 'function',
    ['function'] = {
      name = 'edit_file',
      description = 'Replace a line range with new content. Opens a diff preview in a split and waits for Accept (a) or Reject (q). Range is 1-based inclusive; use end_line = start_line-1 to insert before, or -1/-1 to append.',
      parameters = {
        type = 'object',
        additionalProperties = false,
        required = { 'path', 'start_line', 'end_line', 'new_content' },
        properties = {
          path = { type = 'string', description = 'Target file path' },
          start_line = { type = 'integer', description = '1-based inclusive start line (or -1 for append)' },
          end_line = { type = 'integer', description = '1-based inclusive end line; use start-1 to insert' },
          new_content = { type = 'string', description = 'Replacement text for the range (may be empty to delete)' },
        },
      },
      strict = true,
    },
  },

  output = {
    ---@param self CodeCompanion.Tool.EditFile
    ---@param agent CodeCompanion.Tools.Tool
    ---@param cmd table
    ---@param stdout table
    success = function(self, agent, cmd, stdout)
      local chat = agent.chat
      local result = vim.iter(stdout):flatten():join('\n')
      chat:add_tool_output(self, result, result)
    end,

    ---@param self CodeCompanion.Tool.EditFile
    ---@param agent CodeCompanion.Tools.Tool
    ---@param cmd table
    ---@param stderr table
    error = function(self, agent, cmd, stderr)
      local chat = agent.chat
      local errors = vim.iter(stderr):flatten():join('\n')
      chat:add_tool_output(self, fmt('Edit error: %s', errors))
    end,
  },
}
