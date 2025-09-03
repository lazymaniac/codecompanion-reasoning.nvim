local fmt = string.format

-- Helper functions for better readability and maintainability

---Check if directory is a git repository
---@param root string Project root path
---@return boolean
local function is_git_repo(root)
  local check_cmd = string.format('git -C %s rev-parse --is-inside-work-tree', vim.fn.shellescape(root))
  vim.fn.systemlist(check_cmd)
  return vim.v.shell_error == 0
end

---Validate and normalize paths for directory listing
---@param args table|nil Arguments with optional dir and glob
---@param root string Project root path
---@return table|nil # {base: string, norm_root: string, error: string|nil}
local function validate_and_normalize_paths(args, root)
  args = args or {}
  local dir = args.dir and tostring(args.dir) or '.'

  local base = vim.fs.normalize(vim.fn.fnamemodify(dir, ':p'))
  if not base:find('^' .. vim.pesc(vim.fs.normalize(root))) then
    if not dir:match('^/') then
      base = vim.fs.joinpath(root, dir)
    end
  end

  base = vim.fs.normalize(base)
  local norm_root = vim.fs.normalize(root)

  if base:sub(1, #norm_root) ~= norm_root then
    return { error = fmt("Refusing to list outside project root: '%s'", base) }
  end

  local stat = vim.loop.fs_stat(base)
  if not stat or stat.type ~= 'directory' then
    return { error = fmt("Directory not found: '%s'", base) }
  end

  return { base = base, norm_root = norm_root }
end

---Get relative path from root for display
---@param path string Absolute path
---@param norm_root string Normalized root path
---@return string
local function get_relative_path(path, norm_root)
  local rel = path:sub(#norm_root + 2) -- remove root + '/'
  return (rel and rel ~= '') and rel or path
end

---List files using git with optional glob pattern
---@param base string Base directory path
---@param glob string|nil Optional glob pattern
---@param root string Project root path
---@param norm_root string Normalized root path
---@param max_results number Maximum results limit
---@return table[] # Array of {abs: string, rel: string}
local function list_files_with_git(base, glob, root, norm_root, max_results)
  local results = {}

  local function add_result(path)
    if #results >= max_results then
      return false
    end
    table.insert(results, { abs = path, rel = get_relative_path(path, norm_root) })
    return true
  end

  local base_rel = base:sub(#norm_root + 2)
  if base_rel == '' or base_rel == nil then
    base_rel = '.'
  end

  local list_cmd
  if glob and glob ~= '' then
    local pathspec = base_rel == '.' and string.format(':(glob)%s', glob)
      or string.format(':(glob)%s/%s', base_rel, glob)
    list_cmd = string.format(
      'git -C %s ls-files --cached --others --exclude-standard -- %s',
      vim.fn.shellescape(root),
      vim.fn.shellescape(pathspec)
    )
  else
    list_cmd = base_rel == '.'
        and string.format('git -C %s ls-files --cached --others --exclude-standard', vim.fn.shellescape(root))
      or string.format(
        'git -C %s ls-files --cached --others --exclude-standard -- %s',
        vim.fn.shellescape(root),
        vim.fn.shellescape(base_rel)
      )
  end

  local lines = vim.fn.systemlist(list_cmd)
  if vim.v.shell_error == 0 and type(lines) == 'table' then
    for _, rel in ipairs(lines) do
      if rel and rel ~= '' then
        local abs = vim.fs.normalize(vim.fs.joinpath(norm_root, rel))
        if not add_result(abs) then
          break
        end
      end
    end
  end

  return results
end

---List files using filesystem scan with ignore patterns
---@param base string Base directory path
---@param glob string|nil Optional glob pattern
---@param norm_root string Normalized root path
---@param max_results number Maximum results limit
---@return table[] # Array of {abs: string, rel: string}
local function list_files_with_fs(base, glob, norm_root, max_results)
  local results = {}
  local ignore_dirs = {
    ['.git'] = true,
    ['node_modules'] = true,
    ['deps'] = true,
    ['.venv'] = true,
    ['target'] = true,
    ['dist'] = true,
    ['build'] = true,
  }

  local function add_result(path)
    if #results >= max_results then
      return false
    end
    table.insert(results, { abs = path, rel = get_relative_path(path, norm_root) })
    return true
  end

  if glob and glob ~= '' then
    local list = vim.fn.globpath(base, glob, false, true)
    for _, p in ipairs(list) do
      local s = vim.loop.fs_stat(p)
      if s and s.type == 'file' then
        if not add_result(vim.fs.normalize(p)) then
          break
        end
      end
    end
  else
    local function scan(dirpath)
      if #results >= max_results then
        return
      end

      local fd = vim.loop.fs_scandir(dirpath)
      if not fd then
        return
      end

      while true do
        local name, t = vim.loop.fs_scandir_next(fd)
        if not name then
          break
        end

        local abs = vim.fs.normalize(vim.fs.joinpath(dirpath, name))

        if t == 'directory' then
          if not ignore_dirs[name] then
            scan(abs)
          end
        elseif t == 'file' then
          if not add_result(abs) then
            return
          end
        end

        if #results >= max_results then
          return
        end
      end
    end

    scan(base)
  end

  return results
end

---Format output for display
---@param results table[] Array of file results
---@param norm_root string Normalized root path
---@param base string Base directory path
---@return string
local function format_output(results, norm_root, base)
  table.sort(results, function(a, b)
    return a.rel < b.rel
  end)

  local out = {}
  table.insert(out, fmt('Project root: %s', norm_root))
  table.insert(out, fmt('Base: %s', base))
  table.insert(out, fmt('Results: %d', #results))
  table.insert(out, '')

  for _, r in ipairs(results) do
    table.insert(out, r.rel)
  end

  return table.concat(out, '\n')
end

---@class CodeCompanion.Tool.ListFiles: CodeCompanion.Tools.Tool
---@field name string
---@field cmds fun(self:CodeCompanion.Tool.ListFiles, args:table, input:any):{ status:'success'|'error', data:string }[]
---@field schema table
return {
  name = 'list_files',

  ---List files in the project with optional filters.
  ---@param self CodeCompanion.Tool.ListFiles
  ---@param args { dir?:string, glob?:string }|nil
  ---@param input any
  ---@return { status:'success'|'error', data:string }
  cmds = {
    function(self, args, input)
      args = args or {}
      local root = vim.fn.getcwd()
      local glob = args.glob and tostring(args.glob) or nil
      local MAX_RESULTS = 2000 -- safety guard

      local path_result = validate_and_normalize_paths(args, root)
      if path_result.error then
        return { status = 'error', data = path_result.error }
      end

      local base, norm_root = path_result.base, path_result.norm_root
      local results = {}

      if not args.dir and not args.glob then
        if is_git_repo(root) then
          local list_cmd = fmt('git -C %s ls-files --cached --others --exclude-standard', vim.fn.shellescape(root))
          local lines = vim.fn.systemlist(list_cmd)
          if vim.v.shell_error == 0 and type(lines) == 'table' then
            for _, rel in ipairs(lines) do
              if rel and rel ~= '' then
                table.insert(results, rel)
              end
            end
            table.sort(results)

            local out = {}
            table.insert(out, fmt('Project root: %s', norm_root))
            table.insert(out, fmt('Base: %s', root))
            table.insert(out, fmt('Results: %d', #results))
            table.insert(out, '')
            for _, r in ipairs(results) do
              table.insert(out, r)
            end
            return { status = 'success', data = table.concat(out, '\n') }
          end
        end
      end

      if is_git_repo(root) then
        results = list_files_with_git(base, glob, root, norm_root, MAX_RESULTS)
      else
        results = list_files_with_fs(base, glob, norm_root, MAX_RESULTS)
      end

      local output = format_output(results, norm_root, base)
      return { status = 'success', data = output }
    end,
  },

  schema = {
    type = 'function',
    ['function'] = {
      name = 'list_files',
      description = 'List project files. No args: list all non-ignored files via git (.gitignore respected). With args: list files under dir, optionally filtered by glob.',
      parameters = {
        type = 'object',
        properties = {
          dir = { type = 'string', description = 'Base directory (absolute or relative to project root)' },
          glob = { type = 'string', description = 'Optional glob relative to dir (e.g., **/*.lua or *agent*.lua)' },
        },
        required = {},
        additionalProperties = false,
      },
      strict = true,
    },
  },
  output = {
    ---@param self CodeCompanion.Tool.ListFiles
    ---@param agent CodeCompanion.Tools.Tool
    ---@param cmd table
    ---@param stdout table
    success = function(self, agent, cmd, stdout)
      local chat = agent.chat
      local result = vim.iter(stdout):flatten():join('\n')
      chat:add_tool_output(self, result, result)
    end,
    ---@param self CodeCompanion.Tool.ListFiles
    ---@param agent CodeCompanion.Tools.Tool
    ---@param cmd table
    ---@param stderr table
    error = function(self, agent, cmd, stderr)
      local chat = agent.chat
      local errors = vim.iter(stderr):flatten():join('\n')
      chat:add_tool_output(self, string.format('list_files ERROR: %s', errors))
    end,
  },
}
