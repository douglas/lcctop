require_relative "test_helper"

class TestWaybarOutput < Minitest::Test
  include Lcctop

  def build_session(status:, last_activity: Time.now, **opts)
    Session.new_session(
      session_id:   "test-#{status}",
      project_path: opts.fetch(:project_path, "/home/user/myproject"),
      branch:       opts.fetch(:branch, "main"),
      terminal:     TerminalInfo.new(program: "kitty", session_id: nil, tty: nil),
    ).tap do |s|
      s.status            = status
      s.last_activity     = last_activity
      s.last_prompt       = opts[:last_prompt]
      s.last_tool         = opts[:last_tool]
      s.last_tool_detail  = opts[:last_tool_detail]
      s.notification_message = opts[:notification_message]
      s.session_name      = opts[:session_name]
      s.pid               = opts[:pid]
      s.pid_start_time    = opts[:pid_start_time]
    end
  end

  # --- build: empty ---

  def test_empty_when_no_sessions
    result = WaybarOutput.build([])
    assert_equal "",  result["text"]
    assert_equal "",  result["tooltip"]
    assert_equal "",  result["class"]
  end

  # --- format_text ---

  def test_text_single_session
    sessions = [build_session(status: SessionStatus::WORKING)]
    result = WaybarOutput.build(sessions)
    assert_equal WaybarOutput::ICON, result["text"]
  end

  def test_text_multiple_sessions
    sessions = [
      build_session(status: SessionStatus::WORKING),
      build_session(status: SessionStatus::IDLE),
    ]
    result = WaybarOutput.build(sessions)
    assert_equal "#{WaybarOutput::ICON} 2", result["text"]
  end

  # --- class ---

  def test_class_permission_for_waiting_permission
    sessions = [build_session(status: SessionStatus::WAITING_PERMISSION)]
    assert_equal "permission", WaybarOutput.build(sessions)["class"]
  end

  def test_class_attention_for_waiting_input
    sessions = [build_session(status: SessionStatus::WAITING_INPUT)]
    assert_equal "attention", WaybarOutput.build(sessions)["class"]
  end

  def test_class_attention_for_needs_attention
    sessions = [build_session(status: SessionStatus::NEEDS_ATTENTION)]
    assert_equal "attention", WaybarOutput.build(sessions)["class"]
  end

  def test_class_working
    sessions = [build_session(status: SessionStatus::WORKING)]
    assert_equal "working", WaybarOutput.build(sessions)["class"]
  end

  def test_class_compacting
    sessions = [build_session(status: SessionStatus::COMPACTING)]
    assert_equal "compacting", WaybarOutput.build(sessions)["class"]
  end

  def test_class_idle
    sessions = [build_session(status: SessionStatus::IDLE)]
    assert_equal "idle", WaybarOutput.build(sessions)["class"]
  end

  def test_class_uses_highest_priority_session
    # permission < attention < working < idle (by sort order)
    perm    = build_session(status: SessionStatus::WAITING_PERMISSION)
    working = build_session(status: SessionStatus::WORKING)
    # sorted puts perm first → class should be permission
    sessions = Session.sorted([working, perm])
    assert_equal "permission", WaybarOutput.build(sessions)["class"]
  end

  # --- tooltip ---

  def test_tooltip_includes_project_name_and_status
    sessions = [build_session(status: SessionStatus::WORKING)]
    assert_includes WaybarOutput.build(sessions)["tooltip"], "myproject"
    assert_includes WaybarOutput.build(sessions)["tooltip"], "WORKING"
    assert_includes WaybarOutput.build(sessions)["tooltip"], "main"
  end

  def test_tooltip_includes_context_line_for_working_with_tool
    sessions = [build_session(
      status: SessionStatus::WORKING,
      last_tool: "Bash",
      last_tool_detail: "ls -la",
    )]
    assert_includes WaybarOutput.build(sessions)["tooltip"], "Running: ls -la"
  end

  def test_tooltip_includes_relative_time
    sessions = [build_session(status: SessionStatus::IDLE, last_activity: Time.now - 90)]
    assert_includes WaybarOutput.build(sessions)["tooltip"], "ago"
  end

  def test_tooltip_uses_session_name_when_set
    sessions = [build_session(status: SessionStatus::IDLE, session_name: "My Custom Title")]
    assert_includes WaybarOutput.build(sessions)["tooltip"], "My Custom Title"
  end

  def test_tooltip_multiple_sessions_separated
    sessions = [
      build_session(status: SessionStatus::WAITING_PERMISSION, project_path: "/home/user/proj_a"),
      build_session(status: SessionStatus::IDLE, project_path: "/home/user/proj_b"),
    ]
    tooltip = WaybarOutput.build(sessions)["tooltip"]
    assert_includes tooltip, "proj_a"
    assert_includes tooltip, "proj_b"
  end

  # --- adjust_idle_timeout ---

  def test_idle_timeout_converts_stale_waiting_input_to_idle
    stale = build_session(
      status: SessionStatus::WAITING_INPUT,
      last_activity: Time.now - (WaybarOutput::IDLE_TIMEOUT_SECONDS + 60),
    )
    adjusted = WaybarOutput.adjust_idle_timeout(stale)
    assert_equal SessionStatus::IDLE, adjusted.status
  end

  def test_idle_timeout_preserves_recent_waiting_input
    recent = build_session(
      status: SessionStatus::WAITING_INPUT,
      last_activity: Time.now - 60,
    )
    adjusted = WaybarOutput.adjust_idle_timeout(recent)
    assert_equal SessionStatus::WAITING_INPUT, adjusted.status
  end

  def test_idle_timeout_does_not_affect_other_statuses
    working = build_session(
      status: SessionStatus::WORKING,
      last_activity: Time.now - (WaybarOutput::IDLE_TIMEOUT_SECONDS + 60),
    )
    adjusted = WaybarOutput.adjust_idle_timeout(working)
    assert_equal SessionStatus::WORKING, adjusted.status
  end

  def test_idle_timeout_returns_dup_not_original
    stale = build_session(
      status: SessionStatus::WAITING_INPUT,
      last_activity: Time.now - (WaybarOutput::IDLE_TIMEOUT_SECONDS + 60),
    )
    adjusted = WaybarOutput.adjust_idle_timeout(stale)
    # Original must not be mutated
    assert_equal SessionStatus::WAITING_INPUT, stale.status
    assert_equal SessionStatus::IDLE,          adjusted.status
  end

  # --- adjust_permission_status ---

  def test_permission_status_unchanged_when_no_children
    # Without a real PID we can't spawn children — just verify method returns without raising
    session = build_session(status: SessionStatus::WAITING_PERMISSION, pid: 99999)
    result  = WaybarOutput.adjust_permission_status(session)
    # 99999 has no children, so status remains
    assert_equal SessionStatus::WAITING_PERMISSION, result.status
  end

  def test_permission_status_skipped_when_no_pid
    session = build_session(status: SessionStatus::WAITING_PERMISSION)
    result  = WaybarOutput.adjust_permission_status(session)
    assert_equal SessionStatus::WAITING_PERMISSION, result.status
  end

  # --- format_tooltip (unit) ---

  def test_session_tooltip_lines_idle_omits_context_line
    session = build_session(status: SessionStatus::IDLE)
    lines   = WaybarOutput.session_tooltip_lines(session)
    refute_includes lines, "Compacting"
    refute_includes lines, "Running:"
  end

  def test_session_tooltip_lines_compacting
    session = build_session(status: SessionStatus::COMPACTING)
    assert_includes WaybarOutput.session_tooltip_lines(session), "Compacting context..."
  end
end
