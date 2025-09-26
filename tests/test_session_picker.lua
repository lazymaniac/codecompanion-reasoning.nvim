local h = require('tests.helpers')

local new_set = MiniTest.new_set

local child = MiniTest.new_child_neovim()
local T = new_set({
  hooks = {
    pre_once = function()
      h.child_start(child)
      child.lua([[
        h = require('tests.helpers')
        local tmp = vim.fn.getcwd() .. '/tests/tmp_sessions/picker'
        vim.fn.delete(tmp, 'rf')
        vim.fn.mkdir(tmp, 'p')

        local SessionManager = require('codecompanion._extensions.reasoning.helpers.session_manager')
        SessionManager.setup({
          sessions_dir = tmp,
          auto_load_last_session = false,
        })
      ]])
    end,
    post_once = child.stop,
  },
})

T['session preview shows conversation context'] = function()
  child.lua([[
    local SessionManager = require('codecompanion._extensions.reasoning.helpers.session_manager')
    local tmp = vim.fn.getcwd() .. '/tests/tmp_sessions/picker_preview'
    vim.fn.delete(tmp, 'rf')
    vim.fn.mkdir(tmp, 'p')

    SessionManager.setup({
      sessions_dir = tmp,
      auto_load_last_session = false,
    })

    local now = os.time()
    local session_data = {
      version = '2.0',
      messages = {
        { role = 'user', content = 'Can you summarize the latest deployment steps?' },
        {
          role = 'assistant',
          content = 'Absolutely. First run the migrations, then restart the API pods, and finally warm the cache.',
        },
        { role = 'user', content = 'Include the cache warm command please.' },
        {
          role = 'assistant',
          content = 'Use `make cache:warm --limit=production`. That ensures all nodes are hydrated.',
        },
      },
      metadata = { total_messages = 3 },
      config = { adapter = 'test', model = 'mock-preview' },
      timestamp = now,
      created_at = os.date('%Y-%m-%d %H:%M:%S', now),
    }

    local ok, err = SessionManager.save_session_data(session_data, 'session_preview_extended.lua')
    assert(ok, err)

    local SessionPicker = require('codecompanion._extensions.reasoning.ui.session_picker')
    SessionPicker.show_session_picker(function() end)
    vim.wait(100)

    local preview_buf
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[bufnr].filetype == 'codecompanion-sessions-preview' then
        preview_buf = bufnr
        break
      end
    end
    assert(preview_buf, 'preview buffer not found')

    local lines = vim.api.nvim_buf_get_lines(preview_buf, 0, -1, false)
    local preview = table.concat(lines, '\n')
    assert(
      preview:find('User: Can you summarize the latest deployment steps...', 1, true),
      'expected truncated user prompt'
    )
    assert(
      preview:find('Assistant: Absolutely. First run the migrations, then restart the API pod...', 1, true),
      'expected truncated assistant summary'
    )
    assert(
      preview:find('User: Include the cache warm command please...', 1, true),
      'expected truncated follow-up request'
    )
    assert(preview:find('… 1 more message', 1, true), 'expected overflow indicator for remaining messages')

    local list_buf
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[bufnr].filetype == 'codecompanion-sessions-list' then
        list_buf = bufnr
        break
      end
    end
    if list_buf then
      local list_win = vim.fn.bufwinid(list_buf)
      if list_win ~= -1 then
        vim.api.nvim_set_current_win(list_win)
      end
    end
    vim.api.nvim_input('<Esc>')
    vim.wait(50)
  ]])
end

T['keeps list cursor aligned with selection'] = function()
  child.lua([[
    local SessionManager = require('codecompanion._extensions.reasoning.helpers.session_manager')
    local sessions_dir = SessionManager.get_sessions_dir()

    -- Reset sessions directory for deterministic ordering
    vim.fn.delete(sessions_dir, 'rf')
    vim.fn.mkdir(sessions_dir, 'p')

    local now = os.time()
    for i = 1, 16 do
      local session_data = {
        version = '2.0',
        messages = {},
        metadata = { total_messages = i },
        config = { adapter = 'test', model = 'mock-' .. i },
        timestamp = now + i,
        created_at = os.date('%Y-%m-%d %H:%M:%S', now + i),
        title = ('Session %02d'):format(i),
      }

      local filename = ('session_picker_%02d.lua'):format(i)
      local ok, err = SessionManager.save_session_data(session_data, filename)
      assert(ok, err)
    end

    local SessionPicker = require('codecompanion._extensions.reasoning.ui.session_picker')

    SessionPicker.show_session_picker(function() end)
    vim.wait(100)

    local list_buf
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[bufnr].filetype == 'codecompanion-sessions-list' then
        list_buf = bufnr
        break
      end
    end
    assert(list_buf, 'list buffer not found')

    local list_win = vim.fn.bufwinid(list_buf)
    assert(list_win ~= -1, 'list window not available')

    vim.api.nvim_set_current_win(list_win)

    local nav_callback
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(list_buf, 'n')) do
      if map.lhs == 'j' then
        nav_callback = map.callback
        break
      end
    end
    assert(nav_callback, 'navigation mapping not found')

    local initial_row = vim.api.nvim_win_get_cursor(list_win)[1]

    for _ = 1, 12 do
      nav_callback()
      vim.wait(20)
    end

    local after_row = vim.api.nvim_win_get_cursor(list_win)[1]
    local winline = vim.api.nvim_win_call(list_win, function()
      return vim.fn.winline()
    end)
    local winheight = vim.api.nvim_win_call(list_win, function()
      return vim.fn.winheight(0)
    end)

    vim.api.nvim_input('<Esc>')
    vim.wait(50)

    assert(after_row > initial_row, string.format('expected cursor to move down (initial: %d, after: %d)', initial_row, after_row))
    assert(
      winline >= 1 and winline <= winheight,
      string.format('expected selection to remain in viewport (winline: %d, winheight: %d)', winline, winheight)
    )
  ]])
end

return T
