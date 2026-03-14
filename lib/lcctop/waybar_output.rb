require "json"
require "cgi/escape"

module Lcctop
  module WaybarOutput
    IDLE_TIMEOUT_SECONDS = 3600  # 60 minutes: waiting_input → idle for display

    ICON = "󰚩"

    STATUS_LABEL = {
      SessionStatus::WAITING_PERMISSION => "Permission",
      SessionStatus::WAITING_INPUT      => "Waiting",
      SessionStatus::NEEDS_ATTENTION    => "Attention",
      SessionStatus::WORKING            => "Working",
      SessionStatus::COMPACTING         => "Compacting",
      SessionStatus::IDLE               => "Idle",
    }.freeze

    SOURCE_BADGE_COLOR = {
      "CC" => "#f9e2af",  # amber
      "OC" => "#89b4fa",  # blue
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

    # Catppuccin Mocha palette — matches the CSS color variables in lcctop-waybar.css.tpl.
    STATUS_COLOR = {
      SessionStatus::WAITING_PERMISSION => "#f38ba8",  # red
      SessionStatus::WAITING_INPUT      => "#f9e2af",  # amber
      SessionStatus::NEEDS_ATTENTION    => "#f9e2af",  # amber
      SessionStatus::WORKING            => "#a6e3a1",  # green
      SessionStatus::COMPACTING         => "#89b4fa",  # blue
      SessionStatus::IDLE               => "#6c7086",  # subtext0 (muted)
    }.freeze

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
      header = format_header(sessions)
      cards  = sessions.map { |s| session_tooltip_lines(s) }.join("\n<span color=\"#313244\">────────────────────</span>\n")
      header.empty? ? cards : "#{header}\n<span color=\"#313244\">────────────────────</span>\n#{cards}"
    end

    # Header bar showing colored dot counts per status group, e.g.:
    #   cctop    ● 1  ● 2  ● 1
    def self.format_header(sessions)
      perm    = sessions.count { |s| s.status == SessionStatus::WAITING_PERMISSION }
      attn    = sessions.count { |s| [SessionStatus::WAITING_INPUT, SessionStatus::NEEDS_ATTENTION].include?(s.status) }
      working = sessions.count { |s| [SessionStatus::WORKING, SessionStatus::COMPACTING].include?(s.status) }
      idle    = sessions.count { |s| s.status == SessionStatus::IDLE }

      dots = []
      dots << %(<span color="#f38ba8">● #{perm}</span>)    if perm > 0
      dots << %(<span color="#f9e2af">● #{attn}</span>)    if attn > 0
      dots << %(<span color="#a6e3a1">● #{working}</span>) if working > 0
      dots << %(<span color="#6c7086">● #{idle}</span>)    if idle > 0

      return "" if dots.empty?
      "<b>cctop</b>    #{dots.join("  ")}"
    end

    # Renders one session as two Pango-marked-up lines, matching cctop's card layout:
    #
    #   ▍ project-name  [N agents]  CC/OC    Status
    #     branch / context line                         just now
    #
    def self.session_tooltip_lines(session)
      label  = STATUS_LABEL.fetch(session.status, session.status.capitalize)
      color  = STATUS_COLOR.fetch(session.status, "#6c7086")
      border = %(<span color="#{color}">▍</span>)

      src_color = SOURCE_BADGE_COLOR.fetch(session.source_label, "#f9e2af")
      source    = %(<span color="#{src_color}">#{h session.source_label}</span>)
      agents    = session.subagent_count > 0 ?
        %(  <span color="#cba6f7">[#{session.subagent_count} agents]</span>) : ""

      name_part   = %(<b>#{h session.display_name}</b>#{agents}  #{source})
      status_part = %(<span color="#{color}">#{label}</span>)
      line1       = "#{border} #{name_part}    #{status_part}"

      branch_ctx  = h(session.branch)
      branch_ctx += "  /  #{h session.context_line}" if session.context_line
      time_part   = %(<span color="#6c7086">#{h session.relative_time}</span>)
      line2       = %(  <span color="#6c7086">#{branch_ctx}</span>    #{time_part})

      "#{line1}\n#{line2}"
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

    def self.h(str)
      CGI.escapeHTML(str.to_s)
    end
    private_class_method :h

    private_class_method def self.dup_with_status(session, new_status)
      session.dup.tap { |s| s.status = new_status }
    end
  end
end
