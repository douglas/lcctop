require "json"

module Lcctop
  # Looks up a session's custom name from Claude Code's local data.
  # Port of SessionNameLookup.swift.
  module SessionNameLookup
    def self.lookup(transcript_path:, session_id:)
      return nil unless transcript_path && !transcript_path.empty?

      expanded = File.expand_path(transcript_path)
      name = lookup_from_transcript(expanded)
      return name if name

      dir = File.dirname(expanded)
      lookup_from_index(File.join(dir, "sessions-index.json"), session_id)
    end

    private_class_method def self.lookup_from_transcript(path)
      return nil unless File.exist?(path)
      File.readlines(path).reverse_each do |line|
        next unless line.include?("custom-title")
        parsed = JSON.parse(line)
        if parsed["type"] == "custom-title"
          title = parsed["customTitle"]
          return title if title && !title.empty?
        end
      rescue JSON::ParserError
        next
      end
      nil
    end

    private_class_method def self.lookup_from_index(path, session_id)
      return nil unless File.exist?(path)
      data = JSON.parse(File.read(path))
      entries = data["entries"]
      return nil unless entries.is_a?(Array)
      match = entries.reverse.find { |e| e["sessionId"] == session_id }
      return nil unless match
      title = match["customTitle"]
      title && !title.empty? ? title : nil
    rescue JSON::ParserError
      nil
    end
  end
end
