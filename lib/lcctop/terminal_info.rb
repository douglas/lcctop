module Lcctop
  TerminalInfo = Struct.new(:program, :session_id, :tty, keyword_init: true)

  class TerminalInfo
    SAFE_SESSION_ID_RE = /\A[0-9a-zA-Z:.@_-]+\z/

    def self.capture
      program    = ENV.fetch("TERM_PROGRAM", "")
      session_id = sanitize(ENV["ITERM_SESSION_ID"] || ENV["KITTY_WINDOW_ID"])
      tty        = ENV["TTY"] || find_tty

      new(program:, session_id:, tty:)
    end

    def to_h
      { "program" => program, "session_id" => session_id, "tty" => tty }.compact
    end

    def self.from_h(h)
      return nil unless h
      new(program: h["program"] || "", session_id: h["session_id"], tty: h["tty"])
    end

    private_class_method def self.sanitize(value)
      return nil if value.nil? || value.empty?
      return nil unless value.match?(SAFE_SESSION_ID_RE)
      value
    end

    # Walk up the process tree to find an ancestor with a controlling terminal.
    # The hook subprocess has no tty (stdin is piped JSON), but ancestors do.
    private_class_method def self.find_tty
      pid = Process.ppid
      6.times do
        break if pid <= 1
        tty = tty_of_pid(pid)
        return tty if tty
        pid = ppid_of(pid)
      end
      nil
    end

    private_class_method def self.tty_of_pid(pid)
      content = File.read("/proc/#{pid}/stat")
      right = content.rindex(")")
      return nil unless right
      fields = content[(right + 2)..].split
      tty_nr = fields[4].to_i
      return nil if tty_nr <= 0

      # Try to resolve device number to /dev path
      major = (tty_nr >> 8) & 0xff
      minor = tty_nr & 0xff
      # Common tty device paths
      ["/dev/pts/#{minor}", "/dev/tty#{minor}"].find { |p| File.exist?(p) }
    rescue Errno::ENOENT, Errno::ESRCH, Errno::EPERM
      nil
    end

    private_class_method def self.ppid_of(pid)
      content = File.read("/proc/#{pid}/stat")
      right = content.rindex(")")
      return 0 unless right
      content[(right + 2)..].split[1].to_i
    rescue Errno::ENOENT, Errno::ESRCH, Errno::EPERM
      0
    end
  end
end
