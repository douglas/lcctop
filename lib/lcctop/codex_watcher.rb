require "json"
require "time"

module Lcctop
  module CodexWatcher
    CODEX_SESSIONS_DIR   = File.expand_path("~/.codex/sessions")
    CODEX_SESSIONS_GLOB  = File.join(CODEX_SESSIONS_DIR, "**", "*.jsonl")
    MAX_TRACKED_LOGS     = 64
    POLL_INTERVAL        = ENV.fetch("LCCTOP_CODEX_POLL_INTERVAL", "1.0").to_f
    RECENT_LOG_WINDOW    = 8 * 60 * 60
    TERMINAL_NAMES       = %w[ghostty kitty alacritty wezterm foot].freeze
    TOOL_DETAIL_MAX      = 120

    def self.run
      Config.ensure_dirs
      cleanup_stale_sessions
      watcher = Watcher.new

      stop = false
      %w[INT TERM].each do |sig|
        trap(sig) { stop = true }
      end

      until stop
        watcher.poll
        sleep POLL_INTERVAL
      end
    end

    def self.cleanup_stale_sessions
      Dir.glob(File.join(Config::SESSIONS_DIR, "*.json")).each do |path|
        session = Session.from_file(path)
        next unless session&.source == "codex"
        next unless session.pid.nil? || session.pid == Process.pid || !session.alive?

        File.unlink(path) rescue nil
        File.unlink("#{path}.lock") rescue nil
      end
    rescue StandardError => e
      Logger.log_error("codex watcher cleanup: #{e.class}: #{e.message}")
    end

    class Watcher
      def initialize
        @mirrors = {}
      end

      def poll
        paths = candidate_paths

        paths.each do |path|
          mirror = (@mirrors[path] ||= Mirror.new(path))
          mirror.ingest_new_lines
        rescue StandardError => e
          Logger.log_error("codex watcher poll #{path}: #{e.class}: #{e.message}")
        end

        reap(paths)
      end

      private

      def candidate_paths
        return [] unless Dir.exist?(CODEX_SESSIONS_DIR)

        now = Time.now

        Dir.glob(CODEX_SESSIONS_GLOB)
          .select { |path| recent_enough?(path, now) }
          .sort_by { |path| File.mtime(path) }
          .last(MAX_TRACKED_LOGS)
      rescue StandardError
        []
      end

      def recent_enough?(path, now)
        (now - File.mtime(path)) <= RECENT_LOG_WINDOW
      rescue StandardError
        false
      end

      def reap(active_paths)
        @mirrors.keys.each do |path|
          mirror = @mirrors[path]
          next unless mirror

          if mirror.dead?
            mirror.remove_session
            @mirrors.delete(path)
            next
          end

          next if active_paths.include?(path)
          next if mirror.active?

          mirror.remove_session
          @mirrors.delete(path)
        end
      end
    end

    class Mirror
      attr_reader :log_path, :session

      def initialize(
        log_path,
        pid_resolver: Lcctop::CodexWatcher.method(:resolve_pid_info),
        branch_resolver: Lcctop::CodexWatcher.method(:current_branch),
        terminal_resolver: Lcctop::CodexWatcher.method(:terminal_for_pid)
      )
        @log_path           = log_path
        @pid_resolver       = pid_resolver
        @branch_resolver    = branch_resolver
        @terminal_resolver  = terminal_resolver
        @offset             = 0
        @inode              = nil
        @session            = nil
        @session_file_path  = nil
        @dirty              = false
      end

      def ingest_new_lines
        stat = File.stat(log_path)
        reset_stream_state if @inode != stat.ino || stat.size < @offset
        @inode = stat.ino

        File.open(log_path, "r") do |f|
          f.seek(@offset)
          f.each_line do |line|
            record = JSON.parse(line)
            apply_record(record)
          rescue JSON::ParserError
            next
          end
          @offset = f.pos
        end

        attach_pid_if_needed
        flush if @dirty
      rescue Errno::ENOENT
        nil
      end

      def apply_record(record)
        timestamp = parse_time(record["timestamp"]) || Time.now

        case record["type"]
        when "session_meta"
          build_session(record.fetch("payload", {}), timestamp)
        when "event_msg"
          apply_event(record.fetch("payload", {}), timestamp)
        when "response_item"
          apply_response_item(record.fetch("payload", {}), timestamp)
        end
      end

      def active?
        return false unless File.exist?(log_path)
        return true if session&.pid && session.alive?
        (Time.now - File.mtime(log_path)) <= RECENT_LOG_WINDOW
      rescue StandardError
        false
      end

      def dead?
        session && session.pid && !session.alive?
      end

      def remove_session
        return unless @session_file_path
        File.unlink(@session_file_path) rescue nil
        File.unlink("#{@session_file_path}.lock") rescue nil
      end

      private

      def reset_stream_state
        @offset = 0
        @inode  = nil
      end

      def parse_time(value)
        Time.parse(value) if value
      rescue ArgumentError
        nil
      end

      def build_session(payload, timestamp)
        session_id = payload["id"]
        cwd        = payload["cwd"].to_s
        return if session_id.nil? || session_id.empty? || cwd.empty?

        safe_id    = Session.sanitize_session_id(session_id)
        started_at = parse_time(payload["timestamp"]) || timestamp
        pid_info   = @pid_resolver.call(
          log_path:,
          session_id: safe_id,
          cwd: cwd,
          started_at: started_at,
        )

        terminal = pid_info[:pid] ? @terminal_resolver.call(pid_info[:pid]) : nil

        @session = Session.new_session(
          session_id: safe_id,
          project_path: cwd,
          branch: @branch_resolver.call(cwd),
          terminal: terminal,
        )
        @session.source         = "codex"
        @session.started_at     = started_at
        @session.last_activity  = timestamp
        @session.workspace_file = Session.find_workspace_file(cwd)
        set_pid_info(pid_info)
        @dirty = true
      end

      def apply_event(payload, timestamp)
        return unless @session

        case payload["type"]
        when "user_message"
          clear_tool_state
          @session.status      = SessionStatus::WORKING
          @session.last_prompt = payload["message"] if payload["message"]
        when "task_started"
          @session.status = SessionStatus::WORKING
        when "task_complete", "turn_aborted"
          clear_tool_state
          @session.status = SessionStatus::WAITING_INPUT
        end

        @session.last_activity = timestamp
        @dirty = true
      end

      def apply_response_item(payload, timestamp)
        return unless @session

        case payload["type"]
        when "function_call"
          clear_notification
          @session.status           = SessionStatus::WORKING
          @session.last_tool        = map_tool_name(payload["name"])
          @session.last_tool_detail = extract_tool_detail(payload["name"], payload["arguments"])
        when "web_search_call"
          clear_notification
          @session.status           = SessionStatus::WORKING
          @session.last_tool        = "WebSearch"
          @session.last_tool_detail = nil
        end

        @session.last_activity = timestamp
        @dirty = true
      end

      def clear_notification
        @session.notification_message = nil if @session
      end

      def clear_tool_state
        return unless @session
        @session.last_tool            = nil
        @session.last_tool_detail     = nil
        @session.notification_message = nil
      end

      def attach_pid_if_needed
        return unless @session
        return if @session.pid && @session.alive?

        pid_info = @pid_resolver.call(
          log_path:,
          session_id: @session.session_id,
          cwd: @session.project_path,
          started_at: @session.started_at,
        )
        return unless pid_info[:pid]

        set_pid_info(pid_info)
        @session.terminal ||= @terminal_resolver.call(@session.pid)
        @dirty = true
      end

      def set_pid_info(pid_info)
        return unless @session
        return unless pid_info[:pid]

        old_path = @session_file_path
        @session.pid            = pid_info[:pid]
        @session.pid_start_time = pid_info[:start_time]
        @session_file_path      = File.join(Config::SESSIONS_DIR, "#{@session.pid}.json")

        return unless old_path && old_path != @session_file_path

        File.unlink(old_path) rescue nil
        File.unlink("#{old_path}.lock") rescue nil
      end

      def flush
        return unless @session && @session_file_path
        @session.write_to_file(@session_file_path)
        @dirty = false
      rescue StandardError => e
        Logger.log_error("codex watcher flush #{log_path}: #{e.class}: #{e.message}")
      end

      def map_tool_name(name)
        case name.to_s
        when "exec_command" then "Bash"
        when "apply_patch"  then "Edit"
        else
          base = name.to_s.split(".").last
          base.split("_").map(&:capitalize).join
        end
      end

      def extract_tool_detail(name, arguments)
        case name.to_s
        when "exec_command"
          parsed = JSON.parse(arguments.to_s) rescue {}
          truncate_detail(parsed["cmd"])
        when "apply_patch"
          first = arguments.to_s.each_line.first.to_s.strip
          first.empty? ? nil : truncate_detail(first)
        else
          parsed = JSON.parse(arguments.to_s) rescue {}
          value =
            parsed["cmd"] ||
            parsed["path"] ||
            parsed["file_path"] ||
            parsed["q"] ||
            parsed["query"] ||
            parsed["expression"] ||
            parsed["message"]
          truncate_detail(value)
        end
      end

      def truncate_detail(value)
        return nil if value.nil? || value.empty?
        value.length > TOOL_DETAIL_MAX ? "#{value.slice(0, TOOL_DETAIL_MAX - 3)}..." : value
      end
    end

    def self.resolve_pid_info(log_path:, session_id:, cwd:, started_at:)
      by_fd = find_pid_by_open_fd(log_path)
      return by_fd if by_fd

      candidates = codex_process_candidates
      return {} if candidates.empty?

      candidates
        .map { |pid| score_candidate(pid, session_id:, cwd:, started_at:) }
        .compact
        .max_by { |entry| [entry[:score], -entry[:time_delta]] } || {}
    end

    def self.find_pid_by_open_fd(log_path)
      Dir.glob("/proc/[0-9]*/fd/*").each do |fd_path|
        target = File.readlink(fd_path)
        next unless target == log_path

        pid = fd_path.split("/")[2].to_i
        next if pid == Process.pid
        next if watcher_process?(pid)

        start_time = Session.process_start_time(pid)
        return { pid: pid, start_time: start_time, score: 10_000, time_delta: 0.0 }
      rescue StandardError
        next
      end

      nil
    end

    def self.codex_process_candidates
      Dir.glob("/proc/[0-9]*").filter_map do |proc_dir|
        pid = File.basename(proc_dir).to_i
        next if pid <= 0 || pid == Process.pid

        comm    = File.read(File.join(proc_dir, "comm")).strip.downcase
        cmdline = File.read(File.join(proc_dir, "cmdline")).tr("\0", " ").downcase
        next unless codex_process_candidate?(comm, cmdline)

        pid
      rescue StandardError
        nil
      end
    end

    def self.codex_process_candidate?(comm, cmdline)
      return false if comm.include?("lcctop")
      return false if cmdline.include?("lcctop-codex")

      return true if comm == "codex"

      cmdline.match?(%r{(^|[/\s])codex(\s|$)})
    end

    def self.watcher_process?(pid)
      cmdline = File.read("/proc/#{pid}/cmdline").tr("\0", " ").downcase
      cmdline.include?("lcctop-codex")
    rescue StandardError
      false
    end

    def self.score_candidate(pid, session_id:, cwd:, started_at:)
      proc_cwd = File.readlink("/proc/#{pid}/cwd")
      start    = Session.process_start_time(pid)
      cmdline  = File.read("/proc/#{pid}/cmdline").tr("\0", " ")

      score = 0
      score += 100 if proc_cwd == cwd
      score += 80  if cmdline.include?(session_id)
      score += 40  if cmdline.include?(File.basename(cwd))

      time_delta =
        if start && started_at
          (start - started_at.to_f).abs
        else
          Float::INFINITY
        end

      score += [30 - time_delta.to_i, 0].max if time_delta.finite?
      return nil if score.zero?

      { pid: pid, start_time: start, score: score, time_delta: time_delta }
    rescue StandardError
      nil
    end

    def self.current_branch(cwd)
      output = IO.popen(["git", "-C", cwd, "branch", "--show-current"], err: File::NULL, &:read)
      branch = output.strip
      branch.empty? ? "unknown" : branch
    rescue StandardError
      "unknown"
    end

    def self.terminal_for_pid(pid)
      terminal = terminal_ancestor(pid)
      tty      = tty_for_process_tree(pid)
      program  = terminal&.fetch(:program, "") || ""

      return nil if program.empty? && tty.nil?

      TerminalInfo.new(program: program, session_id: nil, tty: tty, hypr_address: nil)
    end

    def self.terminal_ancestor(pid)
      current = pid
      10.times do
        name = Session.process_name(current).downcase
        return { pid: current, program: name } if TERMINAL_NAMES.include?(name)

        parent = Session.ppid_of(current)
        break if parent <= 1
        current = parent
      end

      nil
    end

    def self.tty_for_process_tree(pid)
      current = pid
      10.times do
        tty = tty_of_pid(current)
        return tty if tty

        parent = Session.ppid_of(current)
        break if parent <= 1
        current = parent
      end

      nil
    end

    def self.tty_of_pid(pid)
      content = File.read("/proc/#{pid}/stat")
      right   = content.rindex(")")
      return nil unless right

      fields = content[(right + 2)..].split
      tty_nr = fields[4].to_i
      return nil if tty_nr <= 0

      minor = tty_nr & 0xff

      ["/dev/pts/#{minor}", "/dev/tty#{minor}"].find { |path| File.exist?(path) }
    rescue StandardError
      nil
    end
  end
end
