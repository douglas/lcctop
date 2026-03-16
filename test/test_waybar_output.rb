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

  def test_disconnected_when_no_sessions
    result = WaybarOutput.build([])
    refute_empty result["text"]
    assert_equal "",             result["tooltip"]
    assert_equal "disconnected", result["class"]
  end

  # --- format_bar_text ---

  def test_text_single_session_includes_icon_and_dot
    sessions = [build_session(status: SessionStatus::WORKING)]
    result = WaybarOutput.build(sessions)
    assert_includes result["text"], WaybarOutput::ICON
    assert_includes result["text"], "●"
    assert_includes result["text"], "#a6e3a1"  # green for working
    assert_nil result["alt"]
  end

  def test_text_multiple_sessions_shows_all_groups
    sessions = [
      build_session(status: SessionStatus::WORKING),
      build_session(status: SessionStatus::IDLE),
    ]
    result = WaybarOutput.build(sessions)
    assert_includes result["text"], "#a6e3a1"  # green for working
    assert_includes result["text"], "#6c7086"  # gray for idle
  end

  # --- class ---

  def test_class_disconnected_when_no_sessions
    assert_equal "disconnected", WaybarOutput.build([])["class"]
  end

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
    perm    = build_session(status: SessionStatus::WAITING_PERMISSION)
    working = build_session(status: SessionStatus::WORKING)
    sessions = Session.sorted([working, perm])
    assert_equal "permission", WaybarOutput.build(sessions)["class"]
  end

  # --- tooltip ---

  def test_tooltip_includes_project_name_and_status
    sessions = [build_session(status: SessionStatus::WORKING)]
    assert_includes WaybarOutput.build(sessions)["tooltip"], "myproject"
    assert_includes WaybarOutput.build(sessions)["tooltip"], "Working"
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
    lines   = WaybarOutput.session_tooltip_lines(session)
    assert_includes lines, "Compacting context..."
    assert_includes lines, "Compacting"
  end

  def test_session_tooltip_lines_status_title_case
    {
      SessionStatus::WAITING_PERMISSION => "Permission",
      SessionStatus::WAITING_INPUT      => "Waiting",
      SessionStatus::WORKING            => "Working",
      SessionStatus::IDLE               => "Idle",
    }.each do |status, label|
      session = build_session(status: status)
      assert_includes WaybarOutput.session_tooltip_lines(session), label, "Expected #{label} for #{status}"
    end
  end

  def test_session_tooltip_lines_cc_badge_amber
    session = build_session(status: SessionStatus::IDLE)
    assert_includes WaybarOutput.session_tooltip_lines(session), "#f9e2af"
    assert_includes WaybarOutput.session_tooltip_lines(session), "CC"
  end

  def test_session_tooltip_lines_time_on_second_line
    session = build_session(status: SessionStatus::IDLE, last_activity: Time.now - 90)
    lines   = WaybarOutput.session_tooltip_lines(session).split("\n")
    assert_equal 2, lines.size
    # Relative time must appear on line 2 only
    refute_includes lines[0], "ago"
    assert_includes lines[1], "ago"
  end

  def test_session_tooltip_lines_no_project_path
    session = build_session(status: SessionStatus::IDLE)
    lines   = WaybarOutput.session_tooltip_lines(session)
    # full path must not appear — only the display name (project_name) is shown
    refute_includes lines, "/home/user/myproject"
    refute_includes lines, "/home/user"
  end

  def test_session_tooltip_lines_agents_when_nonzero
    session = build_session(status: SessionStatus::WORKING)
    session.active_subagents = [
      SubagentInfo.new(agent_id: "a1", agent_type: "general", started_at: nil),
    ]
    assert_includes WaybarOutput.session_tooltip_lines(session), "[1 agents]"
  end

  def test_format_header_shows_dots_for_each_group
    sessions = [
      build_session(status: SessionStatus::WAITING_PERMISSION),
      build_session(status: SessionStatus::WORKING),
      build_session(status: SessionStatus::IDLE),
    ]
    header = WaybarOutput.format_header(sessions)
    assert_includes header, "cctop"
    assert_includes header, "#f38ba8"   # red for permission
    assert_includes header, "#a6e3a1"   # green for working
    assert_includes header, "#6c7086"   # gray for idle
    refute_includes header, "#f9e2af"   # amber (no attention sessions)
  end

  def test_format_header_empty_when_no_sessions
    assert_empty WaybarOutput.format_header([])
  end

  def test_tooltip_includes_header_with_multiple_sessions
    sessions = [
      build_session(status: SessionStatus::WORKING, project_path: "/home/user/proj_a"),
      build_session(status: SessionStatus::IDLE,    project_path: "/home/user/proj_b"),
    ]
    tooltip = WaybarOutput.build(sessions)["tooltip"]
    assert_includes tooltip, "cctop"
  end
end
