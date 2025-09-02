local h = require('tests.helpers')
local MiniTest = require('mini.test')
local expect = MiniTest.expect

local T = MiniTest.new_set({
  hooks = {
    pre_case = function() end,
  },
})

T['adds line numbers to fenced code'] = function()
  local LN = require('codecompanion._extensions.reasoning.helpers.line_numbering')
  local input = [[Here is some code:

```
local x = 1
print(x)
```

Done.]]

  local out = LN.add_numbers_to_fences(input)
  h.expect_contains('\n1 | local x = 1\n', out)
  h.expect_contains('\n2 | print(x)\n', out)
  h.expect_contains('```\n', out) -- opening fence kept
end

T['idempotent numbering on repeated processing'] = function()
  local LN = require('codecompanion._extensions.reasoning.helpers.line_numbering')
  local input = [[```
foo
bar
```
]]
  local once = LN.process(input)
  local twice = LN.process(once)
  h.eq(once, twice)
end

T['preserves multiple code fences'] = function()
  local LN = require('codecompanion._extensions.reasoning.helpers.line_numbering')
  local input = [[Alpha
```
a
b
```
Beta
```
1
2
3
```
Gamma]]
  local out = LN.process(input)
  h.expect_contains('1 | a\n2 | b', out)
  h.expect_contains('1 | 1\n2 | 2\n3 | 3', out)
  h.expect_contains('Alpha', out)
  h.expect_contains('Beta', out)
  h.expect_contains('Gamma', out)
end

return T
