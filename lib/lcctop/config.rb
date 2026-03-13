module Lcctop
  module Config
    SESSIONS_DIR = ENV.fetch("CCTOP_SESSIONS_DIR", File.expand_path("~/.cctop/sessions"))
    LOGS_DIR = File.expand_path("~/.cctop/logs")

    def self.ensure_dirs
      [SESSIONS_DIR, LOGS_DIR].each do |dir|
        FileUtils.mkdir_p(dir, mode: 0o700) unless Dir.exist?(dir)
      end
    end
  end
end
