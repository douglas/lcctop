require "fileutils"
require "time"

module Lcctop
  module Logger
    def self.session_label(cwd:, session_id:)
      project = File.basename(cwd)
      abbrev  = session_id.slice(0, 8)
      "#{project}:#{abbrev}"
    end

    def self.append_hook_log(session_id:, event:, label:, transition:)
      path = session_log_path(session_id)
      return unless path
      ts = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.%3NZ")
      append_line("#{ts} HOOK #{event} #{label} #{transition}\n", path)
    end

    def self.log_error(msg)
      dir = Config::LOGS_DIR
      path = File.join(dir, "_errors.log")
      ts = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.%3NZ")
      append_line("#{ts} ERROR #{msg}\n", path)
    rescue StandardError
      nil  # Never raise from error logger
    end

    def self.cleanup_session_log(session_id)
      path = session_log_path(session_id)
      File.unlink(path) if path && File.exist?(path)
    rescue StandardError
      nil
    end

    private_class_method def self.session_log_path(session_id)
      File.join(Config::LOGS_DIR, "#{session_id}.log")
    end

    private_class_method def self.append_line(line, path)
      FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
      File.open(path, "a", 0o600) { |f| f.write(line) }
    rescue StandardError
      nil
    end
  end
end
