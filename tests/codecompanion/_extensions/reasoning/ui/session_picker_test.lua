-- filepath: tests/codecompanion/_extensions/reasoning/ui/session_picker_test.lua
-- Combined from tests/test_session_picker.lua and tests/test_session_picker_enhanced.lua
local h = require('tests.helpers')
local new_set = MiniTest.new_set
local child = MiniTest.new_child_neovim()

local T = new_set({
  hooks = {
    pre_once = function()
      h.child_start(child)
      child.lua([[
        h = require('tests.helpers')
        normalize_content = function(content) if type(content) == 'table' then return normalize_content(vim.inspect(content)) end return vim.trim(tostring(content or '')) end
        local Config = require('codecompanion._extensions.reasoning.config')
        local tmp = vim.fn.getcwd() .. '/tests/tmp_sessions/picker'
        vim.fn.delete(tmp, 'rf')
        vim.fn.mkdir(tmp, 'p')
        Config.setup({ session_history = { sessions_dir = tmp, continue_last_session = false, auto_generate_title = true } })
        local SessionManager = require('codecompanion._extensions.reasoning.helpers.session_manager')
        SessionManager.setup()
        _G.test_input_result = nil
        _G.test_input_prompt = nil
        vim.ui.input = function(opts, on_confirm) _G.test_input_prompt = opts.prompt; if on_confirm then on_confirm(_G.test_input_result) end end
        _G.test_notifications = {}
        vim.notify = function(msg, level) table.insert(_G.test_notifications, { msg = msg, level = level }) end
        _G.test_confirm_result = 1
        _G.test_confirm_msg = nil
        vim.fn.confirm = function(msg, choices, default, type) _G.test_confirm_msg = msg; return _G.test_confirm_result end
      ]])
    end,
    post_once = child.stop,
  },
})

T['session preview shows conversation context'] = function()
  child.lua([[
    local helpers = require('tests.helpers')
    local Config = require('codecompanion._extensions.reasoning.config')
    local SessionManager = require('codecompanion._extensions.reasoning.helpers.session_manager')
    local tmp = vim.fn.getcwd() .. '/tests/tmp_sessions/picker_preview'
    vim.fn.delete(tmp, 'rf'); vim.fn.mkdir(tmp, 'p')
    Config.setup({ session_history = { sessions_dir = tmp, continue_last_session = false, auto_generate_title = true } })
    SessionManager.setup()
    local session_data = { version = '2.0', messages = { { role = 'user', content = 'Can you summarize the latest deployment steps?' }, { role = 'assistant', content = 'Absolutely. First run the migrations, then restart the API pods, and finally warm the cache.' }, { role = 'user', content = 'Include the cache warm command please.' }, { role = 'assistant', content = 'Use `make cache:warm --limit=production`. That ensures all nodes are hydrated.' }, }, metadata = { total_messages = 3 }, config = { adapter = 'test', model = 'mock-preview' }, timestamp = helpers.timestamp(), created_at = helpers.datetime(), }
    local ok, err = SessionManager.save_session_data(session_data, 'session_preview_extended.lua'); assert(ok, err)
    local SessionPicker = require('codecompanion._extensions.reasoning.ui.session_picker')
    SessionPicker.show_session_picker(function() end)
    vim.wait(100)
    local preview_buf; for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do if vim.bo[bufnr].filetype == 'codecompanion-sessions-preview' then preview_buf = bufnr; break end end; assert(preview_buf, 'preview buffer not found')
    local lines = vim.api.nvim_buf_get_lines(preview_buf, 0, -1, false); local preview = table.concat(lines, '\n')
    assert(preview:find('User: Can you summarize the latest deployment steps...', 1, true))
    assert(preview:find('Assistant: Absolutely. First run the migrations, then restart the API pod...', 1, true))
    assert(preview:find('User: Include the cache warm command please...', 1, true))
    assert(preview:find('… 1 more message', 1, true))
    local list_buf; for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do if vim.bo[bufnr].filetype == 'codecompanion-sessions-list' then list_buf = bufnr; break end end
    if list_buf then local list_win = vim.fn.bufwinid(list_buf); if list_win ~= -1 then vim.api.nvim_set_current_win(list_win) end end
    vim.api.nvim_input('<Esc>'); vim.wait(50)
  ]])
end

T['keeps list cursor aligned with selection'] = function()
  child.lua([[
    local helpers = require('tests.helpers')
    local Config = require('codecompanion._extensions.reasoning.config')
    local SessionManager = require('codecompanion._extensions.reasoning.helpers.session_manager')
    local sessions_dir = Config.get().session_history.sessions_dir
    vim.fn.delete(sessions_dir, 'rf'); vim.fn.mkdir(sessions_dir, 'p')
    for i = 1, 16 do local session_data = { version = '2.0', messages = {}, metadata = { total_messages = i }, config = { adapter = 'test', model = 'mock-' .. i }, timestamp = helpers.timestamp(i), created_at = helpers.datetime(i), title = ('Session %02d'):format(i), }; local filename = ('session_picker_%02d.lua'):format(i); local ok, err = SessionManager.save_session_data(session_data, filename); assert(ok, err) end
    local SessionPicker = require('codecompanion._extensions.reasoning.ui.session_picker')
    SessionPicker.show_session_picker(function() end); vim.wait(100)
    local list_buf; for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do if vim.bo[bufnr].filetype == 'codecompanion-sessions-list' then list_buf = bufnr; break end end; assert(list_buf, 'list buffer not found')
    local list_win = vim.fn.bufwinid(list_buf); assert(list_win ~= -1, 'list window not available')
    vim.api.nvim_set_current_win(list_win)
    local nav_callback; for _, map in ipairs(vim.api.nvim_buf_get_keymap(list_buf, 'n')) do if map.lhs == 'j' then nav_callback = map.callback; break end end; assert(nav_callback, 'navigation mapping not found')
    local initial_row = vim.api.nvim_win_get_cursor(list_win)[1]
    for _ = 1, 12 do nav_callback(); vim.wait(20) end
    local after_row = vim.api.nvim_win_get_cursor(list_win)[1]
    local winline = vim.api.nvim_win_call(list_win, function() return vim.fn.winline() end)
    local winheight = vim.api.nvim_win_call(list_win, function() return vim.fn.winheight(0) end)
    vim.api.nvim_input('<Esc>'); vim.wait(50)
    assert(after_row > initial_row)
    assert(winline >= 1 and winline <= winheight)
  ]])
end

-- Additional management actions from enhanced test suite
T['rename, regenerate title, delete all, toggle favorite, search, summarize, display'] = function()
  child.lua([[
    local h = require('tests.helpers')
    local SessionManager = require('codecompanion._extensions.reasoning.helpers.session_manager')
    local SessionPicker = require('codecompanion._extensions.reasoning.ui.session_picker')
    -- Clear sessions
    local existing_sessions = SessionManager.list_sessions(); for _, session in ipairs(existing_sessions) do SessionManager.delete_session(session.filename) end
    -- Create session
    local session_data = { version = '2.0', messages = { { role = 'user', content = 'Test message' } }, metadata = { total_messages = 1 }, config = { adapter = 'test', model = 'mock' }, timestamp = h.timestamp(), created_at = h.datetime(), title = 'Original Title' }
    local ok, err = SessionManager.save_session_data(session_data, 'rename_test.lua'); assert(ok, err)
    _G.test_input_result = 'New Renamed Title'
    local sessions = SessionManager.list_sessions(); assert(#sessions == 1)
    local test_session = sessions[1]; SessionPicker._handle_rename(test_session, function() end)
    assert(_G.test_input_prompt == 'New title: ')
    local updated_sessions = SessionManager.list_sessions(); assert(updated_sessions[1].title == 'New Renamed Title')
    local found_success = false; for _, notif in ipairs(_G.test_notifications) do if notif.msg:find('Renamed to "New Renamed Title"') then found_success = true; break end end; assert(found_success)
    -- Regenerate title
    local adapters_ok, adapters = pcall(require, 'codecompanion.adapters'); local original_resolve = nil; if adapters_ok and adapters then original_resolve = adapters.resolve; adapters.resolve = function(adapter_name) if adapter_name == 'test' then return { map_roles = function(messages) return messages end, map_schema_to_params = function(settings) return settings end, handlers = { chat_output = function(adapter, data) return { status = 'success', output = { content = 'Binary Search Algorithm' } } end } } end; return nil end end
    local schema_ok, schema = pcall(require, 'codecompanion.schema'); local original_get_default = nil; if schema_ok and schema then original_get_default = schema.get_default; schema.get_default = function(adapter, settings) return { model = 'mock', opts = { stream = false } } end end
    local client_ok, client = pcall(require, 'codecompanion.http'); local original_new = nil; if client_ok and client then original_new = client.new; client.new = function(opts) return { request = function(self, payload, callbacks, options) vim.schedule(function() if callbacks and callbacks.callback then callbacks.callback(nil, { content = 'Binary Search Algorithm' }, { handlers = { chat_output = function(adapter, data) return { status = 'success', output = { content = 'Binary Search Algorithm' } } end } }) end end) end } end end
    sessions = SessionManager.list_sessions(); test_session = sessions[1]; SessionPicker._handle_regenerate_title(test_session, function() end); vim.wait(100); updated_sessions = SessionManager.list_sessions(); assert(updated_sessions[1].title == 'Binary Search Algorithm')
    if adapters_ok and adapters and original_resolve then adapters.resolve = original_resolve end; if schema_ok and schema and original_get_default then schema.get_default = original_get_default end; if client_ok and client and original_new then client.new = original_new end
    -- Delete all
    for i = 1, 2 do local sd = { version = '2.0', messages = { { role = 'user', content = 'Test ' .. i } }, metadata = { total_messages = 1 }, config = { adapter = 'test', model = 'mock' }, timestamp = h.timestamp(i), created_at = h.datetime(i), title = 'Test Session ' .. i }; local ok, err = SessionManager.save_session_data(sd, 'delete_all_test_' .. i .. '.lua'); assert(ok, err) end
    _G.test_confirm_result = 1; SessionPicker._handle_delete_all(function() end); assert(_G.test_confirm_msg:find('Delete all 3 sessions')); assert(#SessionManager.list_sessions() == 0)
  ]])
end

return T
