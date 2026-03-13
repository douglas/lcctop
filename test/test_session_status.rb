require_relative "test_helper"

class TestSessionStatus < Minitest::Test
  include Lcctop

  def test_constants
    assert_equal "idle",               SessionStatus::IDLE
    assert_equal "working",            SessionStatus::WORKING
    assert_equal "compacting",         SessionStatus::COMPACTING
    assert_equal "waiting_permission", SessionStatus::WAITING_PERMISSION
    assert_equal "waiting_input",      SessionStatus::WAITING_INPUT
    assert_equal "needs_attention",    SessionStatus::NEEDS_ATTENTION
  end

  def test_sort_order_priority
    assert SessionStatus.sort_order(SessionStatus::WAITING_PERMISSION) <
           SessionStatus.sort_order(SessionStatus::WORKING)
    assert SessionStatus.sort_order(SessionStatus::WORKING) <
           SessionStatus.sort_order(SessionStatus::IDLE)
  end

  def test_needs_attention
    assert  SessionStatus.needs_attention?(SessionStatus::WAITING_PERMISSION)
    assert  SessionStatus.needs_attention?(SessionStatus::WAITING_INPUT)
    assert  SessionStatus.needs_attention?(SessionStatus::NEEDS_ATTENTION)
    refute  SessionStatus.needs_attention?(SessionStatus::IDLE)
    refute  SessionStatus.needs_attention?(SessionStatus::WORKING)
    refute  SessionStatus.needs_attention?(SessionStatus::COMPACTING)
  end

  def test_parse_known
    assert_equal SessionStatus::IDLE,    SessionStatus.parse("idle")
    assert_equal SessionStatus::WORKING, SessionStatus.parse("working")
  end

  def test_parse_unknown_with_waiting
    assert_equal SessionStatus::NEEDS_ATTENTION, SessionStatus.parse("waiting_something_new")
  end

  def test_parse_unknown_other
    assert_equal SessionStatus::WORKING, SessionStatus.parse("some_future_status")
  end
end
