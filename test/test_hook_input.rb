require_relative "test_helper"

class TestHookInput < Minitest::Test
  include Lcctop

  def parse(extra = {})
    base = {
      "session_id"      => "sess-abc",
      "cwd"             => "/home/user/project",
      "hook_event_name" => "PreToolUse",
    }
    HookInput.parse(JSON.generate(base.merge(extra)))
  end

  def test_parses_required_fields
    input = parse
    assert_equal "sess-abc",        input.session_id
    assert_equal "/home/user/project", input.cwd
    assert_equal "PreToolUse",      input.hook_event_name
  end

  def test_parses_optional_string_fields
    input = parse("prompt" => "hello", "tool_name" => "Bash", "message" => "done")
    assert_equal "hello", input.prompt
    assert_equal "Bash",  input.tool_name
    assert_equal "done",  input.message
  end

  def test_tool_input_string_values_only
    input = parse("tool_input" => { "command" => "ls", "count" => 3, "flag" => true })
    assert_equal({ "command" => "ls" }, input.tool_input)
  end

  def test_tool_input_nil_when_absent
    input = parse
    assert_nil input.tool_input
  end

  def test_raises_on_invalid_json
    assert_raises(ArgumentError) { HookInput.parse("{bad json") }
  end
end
