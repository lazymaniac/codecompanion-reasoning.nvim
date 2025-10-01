return {
  config = {
    adapter = "test",
    model = "reuse"
  },
  messages = { {
      content = "Hello",
      role = "user"
    }, {
      content = "Hi there",
      role = "assistant"
    } },
  metadata = {
    total_messages = 2
  },
  timestamp = 1700000000,
  tools = {},
  version = "2.0"
}