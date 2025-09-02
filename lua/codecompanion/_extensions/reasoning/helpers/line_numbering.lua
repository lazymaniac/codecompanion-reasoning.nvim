-- Line numbering helper for tool outputs
-- Adds 1-based line numbers inside fenced code blocks (``` … ```)

local M = {}

---Split text into lines (preserve empty lines)
---@param s string|nil
---@return string[]
local function split_lines(s)
  if type(s) ~= 'string' or s == '' then
    return {}
  end
  return vim.split(s, '\n', { plain = true })
end

---Check if a code block already looks numbered
---@param block string[]
---@return boolean
local function looks_numbered(block)
  local probe = math.min(3, #block)
  if probe == 0 then
    return false
  end
  for i = 1, probe do
    local line = block[i] or ''
    if not line:match('^%s*%d+%s*[%|%:]%s') then
      return false
    end
  end
  return true
end

---Add left-padded line numbers to a block of lines
---@param block string[]
---@return string[]
local function number_block(block)
  local n = #block
  if n == 0 then
    return {}
  end
  local width = tostring(n):len()
  local out = {}
  for i, line in ipairs(block) do
    out[i] = string.format('%' .. width .. 'd | %s', i, line)
  end
  return out
end

---Add line numbers to fenced code blocks. Idempotent.
---@param text string|nil
---@return string
function M.add_numbers_to_fences(text)
  if type(text) ~= 'string' or text == '' then
    return text or ''
  end

  local lines = split_lines(text)
  local out = {}
  local i = 1
  local max_blocks = 64 -- safety guard
  local blocks_seen = 0

  while i <= #lines do
    local line = lines[i]
    if line:match('^```') then
      -- copy opening fence
      table.insert(out, line)
      i = i + 1

      local block = {}
      while i <= #lines and not lines[i]:match('^```') do
        table.insert(block, lines[i])
        i = i + 1
        if #block > 20000 then -- guard against extreme blocks
          break
        end
      end

      -- transform block if not already numbered
      if looks_numbered(block) then
        vim.list_extend(out, block)
      else
        vim.list_extend(out, number_block(block))
      end

      -- copy closing fence if present
      if i <= #lines and lines[i]:match('^```') then
        table.insert(out, lines[i])
        i = i + 1
      end

      blocks_seen = blocks_seen + 1
      if blocks_seen >= max_blocks then
        -- append remainder untouched
        while i <= #lines do
          table.insert(out, lines[i])
          i = i + 1
        end
        break
      end
    else
      table.insert(out, line)
      i = i + 1
    end
  end

  return table.concat(out, '\n')
end

---Process tool output safely (public API)
---@param s string|nil
---@return string
function M.process(s)
  local ok, result = pcall(M.add_numbers_to_fences, s)
  if ok and type(result) == 'string' then
    return result
  end
  return s or ''
end

return M
