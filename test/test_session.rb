require_relative "test_helper"

class TestSession < Minitest::Test
  include Lcctop

  def setup
    @dir = Dir.mktmpdir
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def build_session(**overrides)
    Session.new_session(
      session_id:   "abc123",
      project_path: "/home/user/myproject",
      branch:       "main",
      terminal:     TerminalInfo.new(program: "kitty", session_id: nil, tty: nil),
    ).tap { |s| overrides.each { |k, v| s.send(:"#{k}=", v) } }
  end

  # --- Sanitize session ID ---

  def test_sanitize_strips_special_chars
    assert_equal "abc-123_OK", Session.sanitize_session_id("abc-123_OK!@#")
  end

  def test_sanitize_truncates_at_64
    long = "a" * 100
    assert_equal 64, Session.sanitize_session_id(long).length
  end

  # --- Extract project name ---

  def test_extract_project_name
    assert_equal "myproject", Session.extract_project_name("/home/user/myproject")
  end

  # --- JSON round-trip ---

  def test_round_trip
    session  = build_session(status: SessionStatus::WORKING, last_prompt: "hello")
    path     = File.join(@dir, "#{Process.pid}.json")
    session.write_to_file(path)

    loaded = Session.from_file(path)
    assert_equal "abc123",    loaded.session_id
    assert_equal "myproject", loaded.project_name
    assert_equal SessionStatus::WORKING, loaded.status
    assert_equal "hello",     loaded.last_prompt
  end

  def test_write_is_atomic
    session = build_session
    path    = File.join(@dir, "12345.json")
    session.write_to_file(path)
    assert File.exist?(path)
    # No temp file should remain
    refute Dir.glob("#{path}.*.tmp").any?
  end

  def test_from_file_returns_nil_for_missing
    assert_nil Session.from_file("/no/such/file.json")
  end

  # --- sorted ---

  def test_sorted_by_priority_then_recency
    working = build_session(status: SessionStatus::WORKING, last_activity: Time.now - 10)
    perm    = build_session(status: SessionStatus::WAITING_PERMISSION, last_activity: Time.now - 20)
    idle    = build_session(status: SessionStatus::IDLE, last_activity: Time.now)

    sorted = Session.sorted([idle, working, perm])
    assert_equal [perm, working, idle].map(&:status), sorted.map(&:status)
  end

  # --- context_line ---

  def test_context_line_idle
    session = build_session(status: SessionStatus::IDLE)
    assert_nil session.context_line
  end

  def test_context_line_compacting
    session = build_session(status: SessionStatus::COMPACTING)
    assert_equal "Compacting context...", session.context_line
  end

  def test_context_line_waiting_permission_with_message
    session = build_session(status: SessionStatus::WAITING_PERMISSION, notification_message: "Allow bash?")
    assert_equal "Allow bash?", session.context_line
  end

  def test_context_line_waiting_permission_fallback
    session = build_session(status: SessionStatus::WAITING_PERMISSION)
    assert_equal "Permission needed", session.context_line
  end

  def test_context_line_working_with_tool
    session = build_session(status: SessionStatus::WORKING, last_tool: "Bash", last_tool_detail: "ls -la")
    assert_equal "Running: ls -la", session.context_line
  end

  def test_context_line_working_with_prompt
    session = build_session(status: SessionStatus::WORKING, last_prompt: "Fix the bug")
    assert_equal "\"Fix the bug\"", session.context_line
  end

  # --- relative_time ---

  def test_relative_time_seconds
    session = build_session(last_activity: Time.now - 30)
    assert_equal "30s ago", session.relative_time
  end

  def test_relative_time_minutes
    session = build_session(last_activity: Time.now - 120)
    assert_equal "2m ago", session.relative_time
  end

  def test_relative_time_hours
    session = build_session(last_activity: Time.now - 3700)
    assert_equal "1h ago", session.relative_time
  end

  # --- subagents ---

  def test_subagent_count
    session = build_session
    session.active_subagents = [
      SubagentInfo.new(agent_id: "a1", agent_type: "general", started_at: Time.now),
    ]
    assert_equal 1, session.subagent_count
  end

  def test_with_session_id
    session  = build_session
    updated  = session.with_session_id("newid", branch: "dev")
    assert_equal "newid",     updated.session_id
    assert_equal "dev",       updated.branch
    assert_equal "abc123",    session.session_id  # original unchanged
  end

  # --- Terminal info round-trip ---

  def test_terminal_info_serializes_in_session
    terminal = TerminalInfo.new(program: "kitty", session_id: "42", tty: "/dev/pts/1")
    session  = build_session(terminal: terminal)
    path     = File.join(@dir, "term_test.json")
    session.write_to_file(path)

    loaded = Session.from_file(path)
    assert_equal "kitty",      loaded.terminal.program
    assert_equal "42",         loaded.terminal.session_id
    assert_equal "/dev/pts/1", loaded.terminal.tty
  end
end
