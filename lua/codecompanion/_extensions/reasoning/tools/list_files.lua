local fmt = string.format

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

      local function default_root()
        -- Prefer current working directory as project root; simple and robust in tests.
        return vim.fn.getcwd()
      end

      local root = default_root()
      local dir = args.dir and tostring(args.dir) or '.'
      local glob = args.glob and tostring(args.glob) or nil
      local MAX_RESULTS = 2000 -- safety guard

      -- Resolve base path safely relative to root
      local base = vim.fs.normalize(vim.fn.fnamemodify(dir, ':p'))
      if not base:find('^' .. vim.pesc(vim.fs.normalize(root))) then
        -- If provided dir is relative, rebase under root
        if not dir:match('^/') then
          base = vim.fs.joinpath(root, dir)
        end
      end

      -- Canonicalize and ensure base exists and is under root
      base = vim.fs.normalize(base)
      local norm_root = vim.fs.normalize(root)
      if base:sub(1, #norm_root) ~= norm_root then
        return { status = 'error', data = fmt("Refusing to list outside project root: '%s'", base) }
      end
      local stat = vim.loop.fs_stat(base)
      if not stat or stat.type ~= 'directory' then
        return { status = 'error', data = fmt("Directory not found: '%s'", base) }
      end

      -- Special case: no args provided -> list all non-ignored project files via git, if available.
      if (not args.dir) and not args.glob then
        local ok_git = true
        -- Check we're inside a git work tree
        local check_cmd = string.format('git -C %s rev-parse --is-inside-work-tree', vim.fn.shellescape(root))
        local _ = vim.fn.systemlist(check_cmd)
        if vim.v.shell_error ~= 0 then
          ok_git = false
        end
        if ok_git then
          local list_cmd =
            string.format('git -C %s ls-files --cached --others --exclude-standard', vim.fn.shellescape(root))
          local lines = vim.fn.systemlist(list_cmd)
          if vim.v.shell_error == 0 and type(lines) == 'table' then
            local results = {}
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
        -- If git is unavailable or fails, fall through to filesystem scan (best-effort without .gitignore rules)
      end

      -- Optional ignore set for common large dirs
      local ignore_dirs = {
        ['.git'] = true,
        ['node_modules'] = true,
        ['deps'] = true,
        ['.venv'] = true,
        ['target'] = true,
        ['dist'] = true,
        ['build'] = true,
      }

      local results = {}

      ---Append a file path if allowed
      ---@param path string absolute path
      local function add_result(path)
        if #results >= MAX_RESULTS then
          return false
        end
        local rel = path:sub(#norm_root + 2) -- remove root + '/'
        if not rel or rel == '' then
          rel = path
        end
        table.insert(results, { abs = path, rel = rel })
        return true
      end

      -- If a glob is supplied, let Neovim expand it efficiently.
      if glob and glob ~= '' then
        -- If in git repo, prefer git to respect .gitignore for globbed queries as well
        local use_git = false
        local check_cmd = string.format('git -C %s rev-parse --is-inside-work-tree', vim.fn.shellescape(root))
        local _ = vim.fn.systemlist(check_cmd)
        if vim.v.shell_error == 0 then
          use_git = true
        end
        if use_git then
          local base_rel = base:sub(#norm_root + 2)
          if base_rel == '' or base_rel == nil then
            base_rel = '.'
          end
          local pathspec
          if base_rel == '.' then
            pathspec = string.format(':(glob)%s', glob)
          else
            pathspec = string.format(':(glob)%s/%s', base_rel, glob)
          end
          local list_cmd = string.format(
            'git -C %s ls-files --cached --others --exclude-standard -- %s',
            vim.fn.shellescape(root),
            vim.fn.shellescape(pathspec)
          )
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
        else
          -- Fallback to filesystem glob (does not honor .gitignore)
          local list = vim.fn.globpath(base, glob, false, true)
          local added = 0
          for _, p in ipairs(list) do
            local s = vim.loop.fs_stat(p)
            if s and s.type == 'file' then
              if add_result(vim.fs.normalize(p)) then
                added = added + 1
                if added >= MAX_RESULTS then
                  break
                end
              else
                break
              end
            end
          end
        end
      else
        -- Recursive scandir with ignore + visibility rules
        local function scan(dirpath)
          if #results >= MAX_RESULTS then
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
            local abs = vim.fs.joinpath(dirpath, name)
            abs = vim.fs.normalize(abs)

            if t == 'directory' then
              if ignore_dirs[name] then
                goto continue
              end
              scan(abs)
              if #results >= MAX_RESULTS then
                return
              end
            elseif t == 'file' then
              if not add_result(abs) then
                return
              end
            end

            ::continue::
          end
        end
        -- If in git repo, prefer git to respect .gitignore even for directory-only search
        local use_git = false
        local check_cmd = string.format('git -C %s rev-parse --is-inside-work-tree', vim.fn.shellescape(root))
        local _ = vim.fn.systemlist(check_cmd)
        if vim.v.shell_error == 0 then
          use_git = true
        end
        if use_git then
          local base_rel = base:sub(#norm_root + 2)
          if base_rel == '' or base_rel == nil then
            base_rel = '.'
          end
          local lines
          if base_rel == '.' then
            local list_cmd =
              string.format('git -C %s ls-files --cached --others --exclude-standard', vim.fn.shellescape(root))
            lines = vim.fn.systemlist(list_cmd)
          else
            local list_cmd = string.format(
              'git -C %s ls-files --cached --others --exclude-standard -- %s',
              vim.fn.shellescape(root),
              vim.fn.shellescape(base_rel)
            )
            lines = vim.fn.systemlist(list_cmd)
          end
          if vim.v.shell_error == 0 and type(lines) == 'table' then
            for _, rel in ipairs(lines) do
              if rel and rel ~= '' then
                local abs = vim.fs.normalize(vim.fs.joinpath(norm_root, rel))
                if not add_result(abs) then
                  break
                end
              end
            end
          else
            scan(base)
          end
        else
          scan(base)
        end
      end

      -- Sort by path by default
      table.sort(results, function(a, b)
        return a.rel < b.rel
      end)

      -- Format output
      local out = {}
      table.insert(out, fmt('Project root: %s', norm_root))
      table.insert(out, fmt('Base: %s', base))
      table.insert(out, fmt('Results: %d', #results))
      table.insert(out, '')
      for _, r in ipairs(results) do
        table.insert(out, r.rel)
      end
      return { status = 'success', data = table.concat(out, '\n') }
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
