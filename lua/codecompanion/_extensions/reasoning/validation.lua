local M = {}

local function value_type(value)
  if value == nil then
    return 'missing'
  end
  if type(value) == 'table' then
    return vim.islist(value) and 'array' or 'object'
  end
  return type(value)
end

local function safe_id(value)
  if type(value) == 'string' and #value <= 32 and value:match('^[A-Z]+%d+$') then
    return value
  end
  return 'invalid_id'
end

local function diagnostic(path, constraint, expected, actual)
  return { path = path, constraint = constraint, expected = expected, actual = actual }
end

function M.required(value, path, expected)
  if value == nil then
    return diagnostic(path, 'required', expected, 'missing')
  end
  if value_type(value) ~= expected then
    return diagnostic(path, 'type', expected, value_type(value))
  end
end

function M.text(value, path, maximum)
  local required = M.required(value, path, 'string')
  if required then
    return required
  end
  local count = vim.fn.strchars(value)
  if vim.trim(value) == '' then
    return diagnostic(path, 'min_chars', 1, count)
  end
  if count > maximum then
    return diagnostic(path, 'max_chars', maximum, count)
  end
end

function M.array(value, path, minimum, maximum)
  local required = M.required(value, path, 'array')
  if required then
    return required
  end
  if #value < minimum then
    return diagnostic(path, 'min_items', minimum, #value)
  end
  if #value > maximum then
    return diagnostic(path, 'max_items', maximum, #value)
  end
end

function M.enum(value, path, allowed)
  if type(value) ~= 'string' then
    return diagnostic(path, 'type', 'string', value_type(value))
  end
  if not allowed[value] then
    local expected = vim.tbl_keys(allowed)
    table.sort(expected)
    return diagnostic(path, 'enum', expected, 'unknown_enum')
  end
end

function M.unique(values, path, key)
  local seen = {}
  for index, value in ipairs(values) do
    local identity = key and key(value) or value
    if seen[identity] then
      return diagnostic(
        ('%s[%d]'):format(path, index),
        'unique_items',
        true,
        safe_id(identity) ~= 'invalid_id' and identity or 'duplicate_value'
      )
    end
    seen[identity] = true
  end
end

function M.reference(workspace, id, path, expected_kind)
  local printable = safe_id(id)
  local artifact = printable ~= 'invalid_id' and workspace.artifacts_by_id[id] or nil
  if not artifact then
    return diagnostic(path, 'artifact_exists', true, printable)
  end
  if artifact.kind ~= expected_kind then
    return diagnostic(path, 'artifact_kind', expected_kind, printable)
  end
  if artifact.status ~= 'active' then
    return diagnostic(path, 'artifact_status', 'active', printable)
  end
end

function M.artifact_ids(values)
  local safe = {}
  for _, id in ipairs(type(values) == 'table' and values or {}) do
    table.insert(safe, safe_id(id))
  end
  return safe
end

function M.diagnostic(path, constraint, expected, actual)
  return diagnostic(path, constraint, expected, actual)
end

return M
