require "json"
require "fileutils"
require "time"

module Lcctop
  SubagentInfo = Struct.new(:agent_id, :agent_type, :started_at, keyword_init: true) do
    def self.from_h(h)
      new(
        agent_id:   h["agent_id"],
        agent_type: h["agent_type"],
        started_at: parse_time(h["started_at"]),
      )
    end

    def to_h
      {
        "agent_id"   => agent_id,
        "agent_type" => agent_type,
        "started_at" => format_time(started_at),
      }.compact
    end

    private_class_method def self.parse_time(s)
      Time.parse(s) if s
    rescue ArgumentError
      nil
    end

    private

    def format_time(t)
      t&.utc&.strftime("%Y-%m-%dT%H:%M:%S.%3NZ")
    end
  end

  # Mutable session record — Struct lets us update fields in-place during hook handling.
  # JSON keys use snake_case matching cctop's Session.swift CodingKeys.
  Session = Struct.new(
    :session_id, :project_path, :project_name, :branch, :status,
    :last_prompt, :last_activity, :started_at, :terminal,
    :pid, :pid_start_time,
    :last_tool, :last_tool_detail, :notification_message,
    :session_name, :workspace_file, :source, :ended_at,
    :active_subagents,
    keyword_init: true,
  ) do
    MAX_PROMPT_SNIPPET = 36
    MAX_TOOL_DETAIL    = 120

    # --- Construction ---

    def self.new_session(session_id:, project_path:, branch:, terminal:)
      now = Time.now
      new(
        session_id:          session_id,
        project_path:        project_path,
        project_name:        extract_project_name(project_path),
        branch:              branch,
        status:              SessionStatus::IDLE,
        last_prompt:         nil,
        last_activity:       now,
        started_at:          now,
        terminal:            terminal,
        pid:                 nil,
        pid_start_time:      nil,
        last_tool:           nil,
        last_tool_detail:    nil,
        notification_message: nil,
        session_name:        nil,
        workspace_file:      nil,
        source:              nil,
        ended_at:            nil,
        active_subagents:    [],
      )
    end

    # --- File I/O ---

    def self.from_file(path)
      from_hash(JSON.parse(File.read(path)))
    rescue Errno::ENOENT
      nil
    rescue JSON::ParserError
      nil
    end

    def write_to_file(path)
      FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
      data = JSON.pretty_generate(to_h_for_json)
      tmp  = "#{path}.#{Process.pid}.tmp"
      File.open(tmp, "w", 0o600) { |f| f.write(data) }
      File.rename(tmp, path)
    rescue StandardError
      File.unlink(tmp) rescue nil
      raise
    end

    # Acquire an exclusive flock on a .lock file, yield, release.
    # Serializes concurrent hook processes on the same session file.
    def self.with_lock(session_path)
      lock_path = "#{session_path}.lock"
      FileUtils.mkdir_p(File.dirname(lock_path), mode: 0o700)
      File.open(lock_path, File::CREAT | File::WRONLY, 0o600) do |f|
        f.flock(File::LOCK_EX)
        yield
      ensure
        f.flock(File::LOCK_UN)
      end
    end

    # --- Utilities ---

    def self.sanitize_session_id(raw)
      raw.gsub(/[^a-zA-Z0-9_-]/, "").slice(0, 64)
    end

    def self.sorted(sessions)
      sessions.sort_by { |s| [SessionStatus.sort_order(s.status), -(s.last_activity&.to_f || 0)] }
    end

    def self.extract_project_name(path)
      File.basename(path.to_s)
    end

    # Return a copy with a new session_id (and optionally updated branch/terminal).
    # Used when the same OS process gets a new CC session_id on resume.
    def with_session_id(new_id, branch: nil, terminal: nil)
      dup.tap do |s|
        s.session_id = new_id
        s.branch     = branch   if branch
        s.terminal   = terminal if terminal
      end
    end

    # Look for a .code-workspace file in the project directory.
    def self.find_workspace_file(project_path)
      entries = Dir.entries(project_path).select { |e| e.end_with?(".code-workspace") }
      return nil if entries.empty?
      if entries.size == 1
        File.join(project_path, entries.first)
      else
        name = File.basename(project_path)
        match = entries.find { |e| File.basename(e, ".code-workspace") == name }
        File.join(project_path, match || entries.first)
      end
    rescue Errno::ENOENT, Errno::ENOTDIR
      nil
    end

    def context_line
      case status
      when SessionStatus::IDLE               then nil
      when SessionStatus::COMPACTING         then "Compacting context..."
      when SessionStatus::WAITING_PERMISSION then notification_message || "Permission needed"
      when SessionStatus::WAITING_INPUT,
           SessionStatus::NEEDS_ATTENTION    then prompt_snippet
      when SessionStatus::WORKING
        last_tool ? format_tool_display(last_tool, last_tool_detail) : prompt_snippet
      end
    end

    def relative_time
      return "just now" unless last_activity
      seconds = (Time.now - last_activity).to_i
      return "just now" if seconds <= 0
      return "#{seconds / 86400}d ago" if seconds >= 86400
      return "#{seconds / 3600}h ago" if seconds >= 3600
      return "#{seconds / 60}m ago"   if seconds >= 60
      "#{seconds}s ago"
    end

    def display_name
      session_name || project_name
    end

    def source_label
      case source
      when "opencode" then "OC"
      when "codex"    then "CX"
      else                 "CC"
      end
    end

    def subagent_count
      active_subagents&.length || 0
    end

    # --- Process Liveness (Linux) ---

    def alive?
      return false unless pid

      begin
        Process.kill(0, pid)
      rescue Errno::ESRCH
        return false
      rescue Errno::EPERM
        # Process exists but we don't have permission — still alive
      end

      # Verify start time to detect PID reuse
      if pid_start_time
        current = self.class.process_start_time(pid)
        return false if current && (current - pid_start_time).abs > 1.0
      end

      stat = self.class.read_proc_stat(pid)
      return false unless stat

      state = stat[0]
      ppid  = stat[1].to_i
      return false if state == "Z"       # zombie
      return false if ppid == 1 && state != "S"  # orphaned (not a normal daemon)

      true
    rescue StandardError
      false
    end

    def self.process_start_time(pid)
      stat = read_proc_stat(pid)
      return nil unless stat
      starttime_ticks = stat[19].to_i  # field 22 in spec, index 19 after stripping pid+comm
      boot = system_boot_time
      return nil unless boot
      boot + starttime_ticks.to_f / clock_ticks_per_second
    rescue StandardError
      nil
    end

    # Parse /proc/{pid}/stat, returning fields after the comm field.
    # Returns [state, ppid, pgrp, session, tty_nr, ..., starttime, ...] or nil.
    def self.read_proc_stat(pid)
      content = File.read("/proc/#{pid}/stat")
      right = content.rindex(")")
      return nil unless right
      content[(right + 2)..].split
    rescue Errno::ENOENT, Errno::ESRCH, Errno::EPERM
      nil
    end

    def self.system_boot_time
      @boot_time ||= begin
        File.readlines("/proc/stat").each do |line|
          return line.split[1].to_f if line.start_with?("btime ")
        end
        nil
      end
    rescue StandardError
      nil
    end

    def self.clock_ticks_per_second
      @clock_ticks ||= begin
        ticks = `getconf CLK_TCK`.strip.to_i
        ticks > 0 ? ticks : 100
      rescue StandardError
        100
      end
    end

    # Walk parent PIDs via /proc, skipping shell intermediaries, to find Claude Code.
    def self.parent_pid_of_hook
      shells = %w[sh bash zsh fish dash].to_set
      pid = Process.ppid
      4.times do
        name = process_name(pid)
        break unless shells.include?(name) || name.end_with?(".sh")
        parent = ppid_of(pid)
        break if parent <= 1
        pid = parent
      end
      pid
    end

    def self.process_name(pid)
      File.read("/proc/#{pid}/comm").strip
    rescue StandardError
      ""
    end

    def self.ppid_of(pid)
      stat = read_proc_stat(pid)
      stat ? stat[1].to_i : 0
    end

    # --- Serialization ---

    def self.from_hash(h)
      new(
        session_id:           h["session_id"] || "",
        project_path:         h["project_path"] || "",
        project_name:         h["project_name"] || "",
        branch:               h["branch"] || "unknown",
        status:               SessionStatus.parse(h["status"] || SessionStatus::IDLE),
        last_prompt:          h["last_prompt"],
        last_activity:        parse_time(h["last_activity"]) || Time.now,
        started_at:           parse_time(h["started_at"]) || Time.now,
        terminal:             TerminalInfo.from_h(h["terminal"]),
        pid:                  h["pid"]&.to_i,
        pid_start_time:       h["pid_start_time"]&.to_f,
        last_tool:            h["last_tool"],
        last_tool_detail:     h["last_tool_detail"],
        notification_message: h["notification_message"],
        session_name:         h["session_name"],
        workspace_file:       h["workspace_file"],
        source:               h["source"],
        ended_at:             parse_time(h["ended_at"]),
        active_subagents:     (h["active_subagents"] || []).map { |a| SubagentInfo.from_h(a) },
      )
    end

    def to_h_for_json
      {
        "session_id"           => session_id,
        "project_path"         => project_path,
        "project_name"         => project_name,
        "branch"               => branch,
        "status"               => status,
        "last_prompt"          => last_prompt,
        "last_activity"        => format_time(last_activity),
        "started_at"           => format_time(started_at),
        "terminal"             => terminal&.to_h,
        "pid"                  => pid,
        "pid_start_time"       => pid_start_time,
        "last_tool"            => last_tool,
        "last_tool_detail"     => last_tool_detail,
        "notification_message" => notification_message,
        "session_name"         => session_name,
        "workspace_file"       => workspace_file,
        "source"               => source,
        "ended_at"             => format_time(ended_at),
        "active_subagents"     => active_subagents&.map(&:to_h),
      }.compact
    end

    private

    def self.parse_time(s)
      Time.parse(s) if s
    rescue ArgumentError
      nil
    end

    def format_time(t)
      t&.utc&.strftime("%Y-%m-%dT%H:%M:%S.%3NZ")
    end

    def prompt_snippet
      return nil unless last_prompt
      "\"#{last_prompt.slice(0, MAX_PROMPT_SNIPPET)}\""
    end

    def format_tool_display(tool, detail)
      return "#{tool}..." unless detail
      file_name = File.basename(detail)
      case tool.downcase
      when "bash"      then "Running: #{detail.slice(0, 30)}"
      when "edit"      then "Editing #{file_name}"
      when "write"     then "Writing #{file_name}"
      when "read"      then "Reading #{file_name}"
      when "grep"      then "Searching: #{detail.slice(0, 30)}"
      when "glob"      then "Finding: #{detail.slice(0, 30)}"
      when "webfetch"  then "Fetching: #{detail.slice(0, 30)}"
      when "websearch" then "Searching: #{detail.slice(0, 30)}"
      when "task",
           "agent"     then "Task: #{detail.slice(0, 30)}"
      else                  "#{tool}: #{detail.slice(0, 30)}"
      end
    end
  end
end
