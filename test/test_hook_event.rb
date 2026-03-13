require_relative "test_helper"

class TestHookEvent < Minitest::Test
  include Lcctop

  def test_parse_known_events
    assert_equal HookEvent::SESSION_START,      HookEvent.parse("SessionStart")
    assert_equal HookEvent::USER_PROMPT_SUBMIT, HookEvent.parse("UserPromptSubmit")
    assert_equal HookEvent::PRE_TOOL_USE,       HookEvent.parse("PreToolUse")
    assert_equal HookEvent::POST_TOOL_USE,      HookEvent.parse("PostToolUse")
    assert_equal HookEvent::STOP,               HookEvent.parse("Stop")
    assert_equal HookEvent::PERMISSION_REQUEST, HookEvent.parse("PermissionRequest")
    assert_equal HookEvent::PRE_COMPACT,        HookEvent.parse("PreCompact")
    assert_equal HookEvent::SESSION_END,        HookEvent.parse("SessionEnd")
  end

  def test_parse_unknown_returns_unknown
    assert_equal HookEvent::UNKNOWN, HookEvent.parse("WeirdHook")
  end

  def test_notification_idle
    assert_equal HookEvent::NOTIFICATION_IDLE, HookEvent.parse("Notification", notification_type: "idle_prompt")
    assert_equal HookEvent::NOTIFICATION_IDLE, HookEvent.parse("Notification", notification_type: "elicitation_dialog")
  end

  def test_notification_permission
    assert_equal HookEvent::NOTIFICATION_PERMISSION, HookEvent.parse("Notification", notification_type: "permission_prompt")
  end

  def test_notification_other
    assert_equal HookEvent::NOTIFICATION_OTHER, HookEvent.parse("Notification", notification_type: "something_else")
    assert_equal HookEvent::NOTIFICATION_OTHER, HookEvent.parse("Notification")
  end

  # --- Transition ---

  def test_transition_session_start_always_idle
    [SessionStatus::WORKING, SessionStatus::IDLE, SessionStatus::COMPACTING].each do |current|
      assert_equal SessionStatus::IDLE, Transition.for_event(current, HookEvent::SESSION_START)
    end
  end

  def test_transition_stop_produces_waiting_input
    assert_equal SessionStatus::WAITING_INPUT, Transition.for_event(SessionStatus::WORKING, HookEvent::STOP)
  end

  def test_transition_prompt_submit_produces_working
    assert_equal SessionStatus::WORKING, Transition.for_event(SessionStatus::IDLE, HookEvent::USER_PROMPT_SUBMIT)
  end

  def test_transition_permission_request
    assert_equal SessionStatus::WAITING_PERMISSION, Transition.for_event(SessionStatus::WORKING, HookEvent::PERMISSION_REQUEST)
  end

  def test_transition_pre_compact
    assert_equal SessionStatus::COMPACTING, Transition.for_event(SessionStatus::WORKING, HookEvent::PRE_COMPACT)
  end

  def test_transition_post_compact
    assert_equal SessionStatus::IDLE, Transition.for_event(SessionStatus::COMPACTING, HookEvent::POST_COMPACT)
  end

  def test_transition_subagent_returns_nil
    assert_nil Transition.for_event(SessionStatus::WORKING, HookEvent::SUBAGENT_START)
    assert_nil Transition.for_event(SessionStatus::WORKING, HookEvent::SUBAGENT_STOP)
  end

  def test_transition_session_end_returns_nil
    assert_nil Transition.for_event(SessionStatus::WORKING, HookEvent::SESSION_END)
  end

  def test_transition_notification_permission_returns_nil
    assert_nil Transition.for_event(SessionStatus::WAITING_PERMISSION, HookEvent::NOTIFICATION_PERMISSION)
  end
end
