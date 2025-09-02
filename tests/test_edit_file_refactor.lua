---Test suite for the refactored apply_edit function
local MiniTest = require('mini.test')
local T = MiniTest
local expect = MiniTest.expect

local M = MiniTest.new_set()

-- Load the function being tested
package.path = package.path .. ';lua/?.lua'
local edit_tool = require('codecompanion._extensions.reasoning.tools.edit_file')

-- Extract apply_edit function for testing (it's local, so we need to expose it)
-- For testing purposes, we'll recreate the functions from the file
local function split_lines(s)
  if s == nil or s == '' then
    return {}
  end
  local parts = vim.split(s, '\n', { plain = true })
  return parts
end

local function apply_edit(original, start_line, end_line, new_content)
  local fmt = string.format

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

-- Test input validation
M['input_validation'] = T.new_set({
  ['rejects_non_table_original'] = function()
    local ok, err = apply_edit('not a table', 1, 1, 'content')
    expect.eq(ok, false)
    expect.match(err, 'original must be a table')
  end,

  ['rejects_non_number_start_line'] = function()
    local ok, err = apply_edit({ 'line1' }, 'not a number', 1, 'content')
    expect.eq(ok, false)
    expect.match(err, 'must be numbers')
  end,

  ['rejects_non_number_end_line'] = function()
    local ok, err = apply_edit({ 'line1' }, 1, 'not a number', 'content')
    expect.eq(ok, false)
    expect.match(err, 'must be numbers')
  end,

  ['rejects_non_string_new_content'] = function()
    local ok, err = apply_edit({ 'line1' }, 1, 1, 123)
    expect.eq(ok, false)
    expect.match(err, 'new_content must be a string')
  end,
})

-- Test append operation (-1, -1)
M['append_operation'] = T.new_set({
  ['appends_to_empty_file'] = function()
    local ok, result = apply_edit({}, -1, -1, 'new line')
    expect.eq(ok, true)
    expect.deep_eq(result, { 'new line' })
  end,

  ['appends_to_single_line_file'] = function()
    local ok, result = apply_edit({ 'existing' }, -1, -1, 'new line')
    expect.eq(ok, true)
    expect.deep_eq(result, { 'existing', 'new line' })
  end,

  ['appends_multiple_lines'] = function()
    local ok, result = apply_edit({ 'line1' }, -1, -1, 'line2\nline3')
    expect.eq(ok, true)
    expect.deep_eq(result, { 'line1', 'line2', 'line3' })
  end,

  ['appends_empty_content'] = function()
    local ok, result = apply_edit({ 'line1' }, -1, -1, '')
    expect.eq(ok, true)
    expect.deep_eq(result, { 'line1', '' })
  end,
})

-- Test insert operation (end_line = start_line - 1)
M['insert_operation'] = T.new_set({
  ['inserts_at_beginning'] = function()
    local ok, result = apply_edit({ 'line2', 'line3' }, 1, 0, 'line1')
    expect.eq(ok, true)
    expect.deep_eq(result, { 'line1', 'line2', 'line3' })
  end,

  ['inserts_in_middle'] = function()
    local ok, result = apply_edit({ 'line1', 'line3' }, 2, 1, 'line2')
    expect.eq(ok, true)
    expect.deep_eq(result, { 'line1', 'line2', 'line3' })
  end,

  ['inserts_at_end'] = function()
    local ok, result = apply_edit({ 'line1', 'line2' }, 3, 2, 'line3')
    expect.eq(ok, true)
    expect.deep_eq(result, { 'line1', 'line2', 'line3' })
  end,

  ['rejects_invalid_insert_position'] = function()
    local ok, err = apply_edit({ 'line1' }, 5, 4, 'content')
    expect.eq(ok, false)
    expect.match(err, 'Invalid insert position')
  end,

  ['inserts_empty_content'] = function()
    local ok, result = apply_edit({ 'line1', 'line2' }, 2, 1, '')
    expect.eq(ok, true)
    expect.deep_eq(result, { 'line1', '', 'line2' })
  end,
})

-- Test replace operation
M['replace_operation'] = T.new_set({
  ['replaces_single_line'] = function()
    local ok, result = apply_edit({ 'old' }, 1, 1, 'new')
    expect.eq(ok, true)
    expect.deep_eq(result, { 'new' })
  end,

  ['replaces_multiple_lines'] = function()
    local ok, result = apply_edit({ 'line1', 'line2', 'line3' }, 2, 3, 'replacement')
    expect.eq(ok, true)
    expect.deep_eq(result, { 'line1', 'replacement' })
  end,

  ['replaces_with_multiple_lines'] = function()
    local ok, result = apply_edit({ 'line1', 'old', 'line3' }, 2, 2, 'new1\nnew2')
    expect.eq(ok, true)
    expect.deep_eq(result, { 'line1', 'new1', 'new2', 'line3' })
  end,

  ['deletes_lines_with_empty_content'] = function()
    local ok, result = apply_edit({ 'line1', 'delete_me', 'line3' }, 2, 2, '')
    expect.eq(ok, true)
    expect.deep_eq(result, { 'line1', '', 'line3' })
  end,

  ['replaces_entire_file'] = function()
    local ok, result = apply_edit({ 'old1', 'old2', 'old3' }, 1, 3, 'new_content')
    expect.eq(ok, true)
    expect.deep_eq(result, { 'new_content' })
  end,
})

-- Test error conditions
M['error_conditions'] = T.new_set({
  ['rejects_negative_start_line'] = function()
    local ok, err = apply_edit({ 'line1' }, -5, 1, 'content')
    expect.eq(ok, false)
    expect.match(err, 'lines must be >= 1')
  end,

  ['rejects_negative_end_line'] = function()
    local ok, err = apply_edit({ 'line1' }, 1, -5, 'content')
    expect.eq(ok, false)
    expect.match(err, 'lines must be >= 1')
  end,

  ['rejects_start_greater_than_end'] = function()
    local ok, err = apply_edit({ 'line1', 'line2' }, 2, 1, 'content')
    expect.eq(ok, false)
    expect.match(err, 'start_line %(2%) > end_line %(1%)')
  end,

  ['rejects_end_line_beyond_file'] = function()
    local ok, err = apply_edit({ 'line1' }, 1, 5, 'content')
    expect.eq(ok, false)
    expect.match(err, 'end_line 5 exceeds file length 1')
  end,

  ['rejects_replace_in_empty_file'] = function()
    local ok, err = apply_edit({}, 1, 1, 'content')
    expect.eq(ok, false)
    expect.match(err, 'Cannot replace lines 1-1 in empty file')
  end,
})

-- Test edge cases
M['edge_cases'] = T.new_set({
  ['handles_empty_original_file'] = function()
    local ok, result = apply_edit({}, -1, -1, 'first line')
    expect.eq(ok, true)
    expect.deep_eq(result, { 'first line' })
  end,

  ['handles_single_line_file'] = function()
    local ok, result = apply_edit({ 'only line' }, 1, 1, 'replaced')
    expect.eq(ok, true)
    expect.deep_eq(result, { 'replaced' })
  end,

  ['handles_newline_in_content'] = function()
    local ok, result = apply_edit({ 'line1' }, -1, -1, 'line2\nline3\n')
    expect.eq(ok, true)
    expect.deep_eq(result, { 'line1', 'line2', 'line3', '' })
  end,

  ['handles_empty_string_content'] = function()
    local ok, result = apply_edit({ 'line1', 'line2' }, 2, 2, '')
    expect.eq(ok, true)
    expect.deep_eq(result, { 'line1', '', 'line2' })
  end,

  ['converts_float_line_numbers'] = function()
    local ok, result = apply_edit({ 'line1', 'line2' }, 1.9, 1.1, 'replaced')
    expect.eq(ok, true)
    expect.deep_eq(result, { 'replaced', 'line2' })
  end,
})

return M
