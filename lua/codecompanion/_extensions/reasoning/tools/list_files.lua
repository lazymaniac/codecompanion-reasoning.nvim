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
        local list = vim.fn.globpath(base, glob, false, true)
        local added = 0
        for _, p in ipairs(list) do
          local s = vim.loop.fs_stat(p)
          if s then
            if s.type == 'file' then
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
        scan(base)
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
      description = 'List project files. Supports base dir and optional glob pattern.',
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
}
