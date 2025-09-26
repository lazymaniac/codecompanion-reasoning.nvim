---@class CodeCompanion.SessionStorage
---File I/O operations for session management
local SessionStorage = {}

local fmt = string.format
local uv = vim.loop

-- Configuration
local CONFIG = {
  sessions_dir = vim.fn.stdpath('data') .. '/codecompanion-reasoning/sessions',
  session_file_pattern = 'session_%Y%m%d_%H%M%S.lua',
  max_sessions = 100,
}

-- Update configuration
---@param new_config table
function SessionStorage.setup(new_config)
  if new_config then
    CONFIG = vim.tbl_deep_extend('force', CONFIG, new_config)
  end
end

-- Ensure sessions directory exists
---@return boolean success
function SessionStorage.ensure_sessions_dir()
  local sessions_dir = CONFIG.sessions_dir
  local stat = uv.fs_stat(sessions_dir)

  if stat then
    if stat.type ~= 'directory' then
      vim.notify(fmt('Sessions path exists but is not a directory: %s', sessions_dir), vim.log.levels.ERROR)
      return false
    end
    return true
  end

  -- Directory doesn't exist, create it with parents
  local success = vim.fn.mkdir(sessions_dir, 'p')
  if success == 0 then
    vim.notify(fmt('Failed to create sessions directory: %s', sessions_dir), vim.log.levels.ERROR)
    return false
  end

  return true
end

-- Generate session filename based on current timestamp
---@return string filename
function SessionStorage.generate_filename()
  local result = os.date(CONFIG.session_file_pattern)
  return type(result) == 'string' and result or 'session_fallback.lua'
end

-- Get full path for session file
---@param filename string
---@return string path
function SessionStorage.get_session_path(filename)
  return CONFIG.sessions_dir .. '/' .. filename
end

-- Write session data to file
---@param session_data table
---@param filename string
---@return boolean success, string? error_message
function SessionStorage.write_session(session_data, filename)
  if not SessionStorage.ensure_sessions_dir() then
    return false, 'Failed to create sessions directory'
  end

  local session_path = SessionStorage.get_session_path(filename)
  local lua_content = 'return ' .. vim.inspect(session_data)

  local file, open_err = io.open(session_path, 'w')
  if not file then
    return false, fmt('Failed to open session file for writing %s: %s', session_path, tostring(open_err))
  end

  local write_success, write_err = pcall(function()
    file:write(lua_content)
  end)
  file:close()

  if not write_success then
    return false, fmt('Failed to write session data to %s: %s', session_path, tostring(write_err))
  end

  return true, nil
end

-- Read session data from file
---@param filename string
---@return table? session_data, string? error_message
function SessionStorage.read_session(filename)
  if not filename or filename == '' then
    return nil, 'Filename cannot be empty'
  end

  local session_path = SessionStorage.get_session_path(filename)
  local file, open_err = io.open(session_path, 'r')
  if not file then
    return nil, fmt('Failed to open session file %s: %s', session_path, tostring(open_err))
  end

  local content, read_err = file:read('*all')
  file:close()

  if not content then
    return nil, fmt('Failed to read session file %s: %s', session_path, tostring(read_err))
  end

  if content == '' then
    return nil, fmt('Session file is empty: %s', session_path)
  end

  local safe_env = {
    pairs = pairs,
    ipairs = ipairs,
    next = next,
    type = type,
    tostring = tostring,
    tonumber = tonumber,
  }

  local chunk, err = load(content, nil, 't', safe_env)
  if not chunk then
    return nil, fmt('Failed to parse session file: %s', err)
  end

  local ok, session_data = pcall(chunk)
  if not ok then
    return nil, fmt('Failed to execute session data: %s', session_data)
  end

  if type(session_data) ~= 'table' then
    return nil, 'Session data is not a valid table structure'
  end

  return session_data, nil
end

-- List session files in directory
---@return table files List of {filename, stat} objects
function SessionStorage.list_session_files()
  if not SessionStorage.ensure_sessions_dir() then
    return {}
  end

  local files = {}
  local handle = uv.fs_scandir(CONFIG.sessions_dir)
  if not handle then
    return files
  end

  while true do
    local name, file_type = uv.fs_scandir_next(handle)
    if not name then
      break
    end

    if file_type == 'file' and name:match('%.lua$') then
      local session_path = SessionStorage.get_session_path(name)
      local stat = uv.fs_stat(session_path)
      if stat then
        table.insert(files, {
          filename = name,
          stat = stat,
          path = session_path,
        })
      end
    end
  end

  return files
end

-- Delete session file
---@param filename string
---@return boolean success, string? error_message
function SessionStorage.delete_session(filename)
  if not filename or filename == '' then
    return false, 'Filename cannot be empty'
  end

  local session_path = SessionStorage.get_session_path(filename)
  local ok, err = vim.uv.fs_unlink(session_path)
  if not ok then
    return false, fmt('Failed to delete session file %s: %s', session_path, err)
  end

  return true, nil
end

-- Get sessions directory path
---@return string path
function SessionStorage.get_sessions_dir()
  return CONFIG.sessions_dir
end

-- Get max sessions configuration
---@return number max_sessions
function SessionStorage.get_max_sessions()
  return CONFIG.max_sessions
end

return SessionStorage
