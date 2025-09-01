return {
  config = {
    adapter = "test",
    model = "mock"
  },
  messages = { {
      content = "Please ask me a question",
      role = "user"
    }, {
      content = "",
      role = "assistant",
      tool_calls = { {
          ["function"] = {
            arguments = '{"q":"hi"}',
            name = "ask_user"
          },
          id = "abc"
        } }
    }, {
      content = "Answer: hello",
      role = "tool",
      tool_call_id = "abc",
      tool_name = "ask_user"
    }, {
      content = "Thanks!",
      role = "assistant"
    } },
  metadata = {
    total_messages = 4
  },
  timestamp = 1756722258,
  tools = { "ask_user" },
  version = "2.0"
}