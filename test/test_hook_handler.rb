require_relative "test_helper"

class TestHookHandler < Minitest::Test
  include Lcctop

  # Exercise the private extract_tool_detail logic via a full handle() call.
  # We stub out process-level helpers to avoid needing a real PID tree.

  def setup
    @dir = Dir.mktmpdir
    # Override sessions dir via env
    @orig_dir = Config::SESSIONS_DIR
    # Hack: redefine constant for test isolation
    Lcctop::Config.send(:remove_const, :SESSIONS_DIR) rescue nil
    Lcctop::Config.const_set(:SESSIONS_DIR, @dir)
  end

  def teardown
    FileUtils.rm_rf(@dir)
    Lcctop::Config.send(:remove_const, :SESSIONS_DIR) rescue nil
    Lcctop::Config.const_set(:SESSIONS_DIR, @orig_dir)
  end

  def make_input(hook_name, **extra)
    base = {
      "session_id"      => "test-session-1",
      "cwd"             => "/tmp/testproject",
      "hook_event_name" => hook_name,
    }
    HookInput.new(base.merge(extra.transform_keys(&:to_s)))
  end

  FAKE_PID = 99999

  def run_hook(hook_name, **extra)
    input = make_input(hook_name, **extra)
    HookHandler.handle(hook_name, input, pid: FAKE_PID)
  end

  def load_session
    Session.from_file(File.join(@dir, "#{FAKE_PID}.json"))
  end

  # --- Basic state transitions via handle() ---

  def test_session_start_creates_file
    run_hook("SessionStart")
    session = load_session
    assert session, "session file should be created"
    assert_equal "test-session-1", session.session_id
    assert_equal SessionStatus::IDLE, session.status
  end

  def test_user_prompt_submit_sets_working_and_prompt
    run_hook("SessionStart")
    run_hook("UserPromptSubmit", prompt: "Fix the tests")
    session = load_session
    assert_equal SessionStatus::WORKING, session.status
    assert_equal "Fix the tests", session.last_prompt
  end

  def test_pre_tool_use_sets_tool_detail
    run_hook("SessionStart")
    run_hook("PreToolUse", tool_name: "Bash", tool_input: { "command" => "ls -la" })
    session = load_session
    assert_equal "Bash",  session.last_tool
    assert_equal "ls -la", session.last_tool_detail
  end

  def test_stop_sets_waiting_input
    run_hook("SessionStart")
    run_hook("UserPromptSubmit", prompt: "hello")
    run_hook("Stop")
    session = load_session
    assert_equal SessionStatus::WAITING_INPUT, session.status
  end

  def test_permission_request_sets_waiting_permission
    run_hook("SessionStart")
    run_hook("PermissionRequest", tool_name: "Bash", tool_input: { "command" => "rm -rf /" })
    session = load_session
    assert_equal SessionStatus::WAITING_PERMISSION, session.status
    assert session.notification_message.include?("Bash")
  end

  def test_session_end_removes_file
    run_hook("SessionStart")
    assert File.exist?(File.join(@dir, "99999.json"))
    run_hook("SessionEnd")
    refute File.exist?(File.join(@dir, "99999.json"))
  end

  def test_subagent_start_adds_to_list
    run_hook("SessionStart")
    run_hook("SubagentStart", agent_id: "agent-1", agent_type: "general-purpose")
    session = load_session
    assert_equal 1, session.subagent_count
    assert_equal "agent-1", session.active_subagents.first.agent_id
  end

  def test_subagent_stop_removes_from_list
    run_hook("SessionStart")
    run_hook("SubagentStart", agent_id: "agent-1", agent_type: "general-purpose")
    run_hook("SubagentStop", agent_id: "agent-1")
    session = load_session
    assert_equal 0, session.subagent_count
  end
end
