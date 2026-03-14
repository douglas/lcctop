require "json"

module Lcctop
  module WaybarOutput
    IDLE_TIMEOUT_SECONDS = 3600  # 60 minutes: waiting_input → idle for display

    ICON = "󰚩"

    STATUS_LABEL = {
      SessionStatus::WAITING_PERMISSION => "PERMISSION",
      SessionStatus::WAITING_INPUT      => "WAITING",
      SessionStatus::NEEDS_ATTENTION    => "ATTENTION",
      SessionStatus::WORKING            => "WORKING",
      SessionStatus::COMPACTING         => "COMPACTING",
      SessionStatus::IDLE               => "IDLE",
    }.freeze

    # Build Waybar JSON from the current sessions directory.
    # Returns a Hash ready for JSON.generate.
    def self.render
      sessions = load_alive_sessions
      build(sessions)
    end

    def self.load_alive_sessions
      dir = Config::SESSIONS_DIR
      return [] unless Dir.exist?(dir)

      Dir.glob(File.join(dir, "*.json"))
        .filter_map { |path| Session.from_file(path) }
        .select(&:alive?)
        .map { |s| adjust_display_status(s) }
        .then { |sessions| Session.sorted(sessions) }
    end

    # Maps session status to waybar CSS class (applied to #custom-lcctop).
    STATUS_CLASS = {
      SessionStatus::WAITING_PERMISSION => "permission",
      SessionStatus::WAITING_INPUT      => "attention",
      SessionStatus::NEEDS_ATTENTION    => "attention",
      SessionStatus::WORKING            => "working",
      SessionStatus::COMPACTING         => "compacting",
      SessionStatus::IDLE               => "idle",
    }.freeze

    # Build the Waybar JSON hash from a pre-sorted list of display-adjusted sessions.
    # text  → plain string so waybar doesn't hide the module
    # alt   → session count suffix shown via "󰚩{alt}" format in waybar config
    # class → CSS class for status color (disconnected when no sessions)
    def self.build(sessions)
      if sessions.empty?
        { "text" => "lcctop", "alt" => "", "tooltip" => "", "class" => "disconnected" }
      else
        n = sessions.size
        {
          "text"    => "lcctop",
          "alt"     => n > 1 ? " #{n}" : "",
          "tooltip" => format_tooltip(sessions),
          "class"   => STATUS_CLASS.fetch(sessions.first.status, "idle"),
        }
      end
    end

    # --- Display adjustments (view-only, session files not modified) ---

    def self.adjust_display_status(session)
      session = adjust_idle_timeout(session)
      session = adjust_permission_status(session)
      session
    end

    # waiting_input that's been idle for > 60 min → treat as idle for display.
    def self.adjust_idle_timeout(session)
      return session unless session.status == SessionStatus::WAITING_INPUT
      return session unless session.last_activity
      return session if (Time.now - session.last_activity) <= IDLE_TIMEOUT_SECONDS
      dup_with_status(session, SessionStatus::IDLE)
    end

    # waiting_permission + a child process that started after lastActivity →
    # the user granted permission and a tool is running; show as working.
    def self.adjust_permission_status(session)
      return session unless session.status == SessionStatus::WAITING_PERMISSION
      return session unless session.pid && session.last_activity

      cutoff = session.last_activity.to_f - 1.0  # 1s tolerance for jitter

      list_child_pids(session.pid).each do |child_pid|
        start_time = Session.process_start_time(child_pid)
        return dup_with_status(session, SessionStatus::WORKING) if start_time && start_time > cutoff
      end

      session
    end

    # --- Formatting ---

    def self.format_text(sessions)
      n = sessions.size
      n == 1 ? ICON : "#{ICON} #{n}"
    end

    def self.format_tooltip(sessions)
      sessions.map { |s| session_tooltip_lines(s) }.join("\n\n")
    end

    def self.session_tooltip_lines(session)
      label  = STATUS_LABEL.fetch(session.status, session.status.upcase)
      header = "#{session.display_name}  #{label}  #{session.branch}"
      lines  = [header]
      lines << session.context_line if session.context_line
      lines << session.relative_time
      lines.join("\n")
    end

    # --- Linux child PID enumeration ---

    # Find direct children of pid by scanning /proc/*/stat for ppid matches.
    def self.list_child_pids(pid)
      Dir.glob("/proc/[0-9]*/stat").filter_map do |path|
        content = File.read(path)
        right   = content.rindex(")")
        next unless right
        fields = content[(right + 2)..].split
        next unless fields[1].to_i == pid
        File.basename(File.dirname(path)).to_i
      rescue Errno::ENOENT, Errno::ESRCH, Errno::EPERM
        nil
      end
    end

    private_class_method def self.dup_with_status(session, new_status)
      session.dup.tap { |s| s.status = new_status }
    end
  end
end
