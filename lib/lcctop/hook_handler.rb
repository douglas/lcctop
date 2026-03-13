require "fileutils"

module Lcctop
  module HookHandler
    MAX_TOOL_DETAIL = 120

    def self.handle(hook_name, input, pid: nil)
      event = HookEvent.parse(hook_name, notification_type: input.notification_type)

      if event == HookEvent::SESSION_END
        handle_session_end(hook_name, input, pid:)
        return
      end

      sessions_dir = Config::SESSIONS_DIR
      FileUtils.mkdir_p(sessions_dir, mode: 0o700)

      safe_id      = Session.sanitize_session_id(input.session_id)
      pid        ||= Session.parent_pid_of_hook
      label        = Logger.session_label(cwd: input.cwd, session_id: safe_id)
      session_path = File.join(sessions_dir, "#{pid}.json")

      branch     = current_branch(input.cwd)
      terminal   = TerminalInfo.capture
      start_time = Session.process_start_time(pid)

      Session.with_lock(session_path) do
        fresh   = Session.new_session(session_id: safe_id, project_path: input.cwd, branch: branch, terminal: terminal)
        session = load_or_create(path: session_path, event: event, start_time: start_time, fresh: fresh)

        session.pid            = pid
        session.pid_start_time = start_time

        old_status, new_status = apply_transition(session, event: event, input: input, branch: branch, terminal: terminal)
        apply_side_effects(session, event: event, input: input, sessions_dir: sessions_dir, safe_id: safe_id)

        suffix = new_status ? "" : " (preserved)"
        Logger.append_hook_log(
          session_id: safe_id, event: hook_name, label: label,
          transition: "#{old_status} -> #{session.status}#{suffix}",
        )
        session.write_to_file(session_path)
      end

      # Cleanup runs outside the lock — scans all session files, would hold lock unnecessarily
      cleanup_for_project(sessions_dir: sessions_dir, project_path: input.cwd, current_pid: pid) if event == HookEvent::SESSION_START
    end

    # --- Private ---

    private_class_method def self.apply_transition(session, event:, input:, branch:, terminal:)
      old_status = session.status
      new_status = Transition.for_event(session.status, event)
      session.status = new_status if new_status

      # Skip lastActivity for late notificationPermission — PermissionRequest already set it
      session.last_activity = Time.now unless event == HookEvent::NOTIFICATION_PERMISSION

      session.branch   = branch
      session.terminal = terminal

      if event == HookEvent::SESSION_START || event == HookEvent::USER_PROMPT_SUBMIT
        session.session_name = SessionNameLookup.lookup(
          transcript_path: input.transcript_path,
          session_id: input.session_id,
        )
      end

      [old_status, new_status]
    end

    private_class_method def self.apply_side_effects(session, event:, input:, sessions_dir:, safe_id:)
      case event
      when HookEvent::SESSION_START
        clear_tool_state(session)
        session.active_subagents = []
        session.workspace_file   = Session.find_workspace_file(input.cwd)

      when HookEvent::USER_PROMPT_SUBMIT
        clear_tool_state(session)
        session.last_prompt = input.prompt if input.prompt

      when HookEvent::PRE_TOOL_USE
        if input.tool_name
          session.last_tool        = input.tool_name
          session.last_tool_detail = extract_tool_detail(input.tool_name, input.tool_input)
        end

      when HookEvent::PERMISSION_REQUEST
        msg = input.title || build_permission_msg(input.tool_name, input.tool_input)
        session.notification_message = msg

      when HookEvent::NOTIFICATION_IDLE, HookEvent::NOTIFICATION_OTHER
        session.last_tool             = nil
        session.last_tool_detail      = nil
        session.notification_message  = input.message if input.message

      when HookEvent::STOP
        clear_tool_state(session)

      when HookEvent::POST_TOOL_USE_FAILURE
        session.notification_message = input.error if input.error

      when HookEvent::SUBAGENT_START
        apply_subagent_start(session, input)

      when HookEvent::SUBAGENT_STOP
        apply_subagent_stop(session, input)

      when HookEvent::SESSION_ERROR
        session.notification_message = input.error || input.message
      end
    end

    private_class_method def self.clear_tool_state(session)
      session.last_tool             = nil
      session.last_tool_detail      = nil
      session.notification_message  = nil
    end

    private_class_method def self.apply_subagent_start(session, input)
      return unless input.agent_id && input.agent_type
      session.active_subagents ||= []
      return if session.active_subagents.any? { |a| a.agent_id == input.agent_id }
      session.active_subagents << SubagentInfo.new(
        agent_id:   input.agent_id,
        agent_type: input.agent_type,
        started_at: Time.now,
      )
    end

    private_class_method def self.apply_subagent_stop(session, input)
      return unless input.agent_id
      session.active_subagents&.reject! { |a| a.agent_id == input.agent_id }
    end

    private_class_method def self.load_or_create(path:, event:, start_time:, fresh:)
      existing = Session.from_file(path)
      return fresh unless existing

      # PID reuse: different start time means a new process reused this PID
      if event == HookEvent::SESSION_START && existing.pid_start_time && start_time
        return fresh if (existing.pid_start_time - start_time).abs > 1.0
      end

      # Same process but CC assigned a new session_id (e.g. resume) — carry over state
      return existing.with_session_id(fresh.session_id, branch: fresh.branch, terminal: fresh.terminal) \
        unless existing.session_id == fresh.session_id

      existing
    end

    private_class_method def self.handle_session_end(hook_name, input, pid: nil)
      sessions_dir = Config::SESSIONS_DIR
      pid        ||= Session.parent_pid_of_hook
      safe_id      = Session.sanitize_session_id(input.session_id)
      session_path = File.join(sessions_dir, "#{pid}.json")
      label        = Logger.session_label(cwd: input.cwd, session_id: safe_id)

      Logger.append_hook_log(session_id: safe_id, event: hook_name, label: label, transition: "-> removed")
      remove_session(session_path, safe_id)
    end

    private_class_method def self.cleanup_for_project(sessions_dir:, project_path:, current_pid:)
      Dir.glob(File.join(sessions_dir, "*.json")).each do |path|
        session = Session.from_file(path)
        next unless session
        next unless session.project_path == project_path
        next if session.pid == current_pid

        stale = if session.pid
          !pid_alive?(session.pid) ||
            (session.pid_start_time &&
              (start = Session.process_start_time(session.pid)) &&
              (session.pid_start_time - start).abs > 1.0)
        else
          (Time.now - session.last_activity) > 300
        end

        remove_session(path, session.session_id) if stale
      end
    rescue StandardError
      nil
    end

    private_class_method def self.remove_session(path, session_id)
      File.unlink(path) rescue nil
      File.unlink("#{path}.lock") rescue nil
      Logger.cleanup_session_log(session_id)
    end

    private_class_method def self.pid_alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    private_class_method def self.build_permission_msg(tool_name, tool_input)
      return nil unless tool_name
      detail = extract_tool_detail(tool_name, tool_input)
      detail ? "#{tool_name}: #{detail}" : tool_name
    end

    private_class_method def self.extract_tool_detail(tool_name, tool_input)
      return nil unless tool_input

      field = case tool_name.downcase
              when "bash"             then "command"
              when "edit", "write",
                   "read"            then "file_path"
              when "grep", "glob"    then "pattern"
              when "webfetch"        then "url"
              when "websearch"       then "query"
              when "task", "agent"   then "description"
              else return nil
              end

      value = tool_input[field]
      return nil if value.nil? || value.empty?
      value.length > MAX_TOOL_DETAIL ? "#{value.slice(0, MAX_TOOL_DETAIL - 3)}..." : value
    end

    private_class_method def self.current_branch(cwd)
      output = IO.popen(["git", "-C", cwd, "branch", "--show-current"], err: File::NULL, &:read)
      branch = output.strip
      branch.empty? ? "unknown" : branch
    rescue StandardError
      "unknown"
    end
  end
end
