require_relative "test_helper"

class TestCodexWatcher < Minitest::Test
  include Lcctop

  def setup
    @theme_colors_file_env = ENV["LCCTOP_THEME_COLORS_FILE"]
  end

  def teardown
    ENV["LCCTOP_THEME_COLORS_FILE"] = @theme_colors_file_env
  end

  def build_mirror
    Lcctop::CodexWatcher::Mirror.new(
      "/tmp/test-codex.jsonl",
      pid_resolver: ->(**) { { pid: 4242, start_time: 123.0 } },
      branch_resolver: ->(_cwd) { "main" },
      terminal_resolver: ->(_pid) { TerminalInfo.new(program: "ghostty", session_id: nil, tty: "/dev/pts/9") }
    )
  end

  def test_session_meta_creates_codex_session
    mirror = build_mirror
    mirror.apply_record(
      "timestamp" => "2026-04-08T23:50:40.601Z",
      "type" => "session_meta",
      "payload" => {
        "id" => "019d6f81-56d1-7f50-bca6-ff501b83d877",
        "cwd" => "/home/user/project",
      },
    )

    session = mirror.session
    assert_equal "codex", session.source
    assert_equal "main", session.branch
    assert_equal 4242, session.pid
    assert_equal "ghostty", session.terminal.program
    assert_equal SessionStatus::IDLE, session.status
  end

  def test_user_message_and_task_complete_transition
    mirror = build_mirror
    mirror.apply_record(
      "timestamp" => "2026-04-08T23:50:40.601Z",
      "type" => "session_meta",
      "payload" => { "id" => "sess-1", "cwd" => "/home/user/project" },
    )

    mirror.apply_record(
      "timestamp" => "2026-04-08T23:50:41.000Z",
      "type" => "event_msg",
      "payload" => { "type" => "user_message", "message" => "Fix the tests" },
    )
    assert_equal SessionStatus::WORKING, mirror.session.status
    assert_equal "Fix the tests", mirror.session.last_prompt

    mirror.apply_record(
      "timestamp" => "2026-04-08T23:50:50.000Z",
      "type" => "event_msg",
      "payload" => { "type" => "task_complete" },
    )
    assert_equal SessionStatus::WAITING_INPUT, mirror.session.status
    assert_nil mirror.session.last_tool
  end

  def test_function_call_maps_exec_command_to_bash
    mirror = build_mirror
    mirror.apply_record(
      "timestamp" => "2026-04-08T23:50:40.601Z",
      "type" => "session_meta",
      "payload" => { "id" => "sess-1", "cwd" => "/home/user/project" },
    )

    mirror.apply_record(
      "timestamp" => "2026-04-08T23:50:42.000Z",
      "type" => "response_item",
      "payload" => {
        "type" => "function_call",
        "name" => "exec_command",
        "arguments" => JSON.generate("cmd" => "bundle exec rake test"),
      },
    )

    assert_equal SessionStatus::WORKING, mirror.session.status
    assert_equal "Bash", mirror.session.last_tool
    assert_equal "bundle exec rake test", mirror.session.last_tool_detail
  end

  def test_default_resolvers_bind_to_codex_watcher_module
    mirror = Lcctop::CodexWatcher::Mirror.new("/tmp/test-codex.jsonl")

    Dir.mktmpdir do |dir|
      project_dir = File.join(dir, "project")
      Dir.mkdir(project_dir)

      mirror.apply_record(
        "timestamp" => "2026-04-08T23:50:40.601Z",
        "type" => "session_meta",
        "payload" => { "id" => "sess-1", "cwd" => project_dir },
      )
    end

    assert_equal "codex", mirror.session.source
    assert_equal "unknown", mirror.session.branch
  end

  def test_codex_process_candidate_filter_rejects_lcctop_watcher
    refute Lcctop::CodexWatcher.codex_process_candidate?("lcctop-codex", "/home/douglas/.local/bin/lcctop-codex")
    refute Lcctop::CodexWatcher.codex_process_candidate?("ruby", "ruby /home/douglas/.local/bin/lcctop-codex")
    assert Lcctop::CodexWatcher.codex_process_candidate?("codex", "/usr/bin/codex")
    assert Lcctop::CodexWatcher.codex_process_candidate?("bwrap", "/vendor/codex/codex --sandbox-policy")
  end
end
