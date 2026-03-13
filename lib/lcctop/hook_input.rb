require "json"

module Lcctop
  # Parses Claude Code hook JSON from stdin into a plain Ruby object.
  # Mirrors HookInput.swift — keys are snake_case, tool_input skips non-string values.
  class HookInput
    attr_reader :session_id, :cwd, :transcript_path, :permission_mode,
                :hook_event_name, :prompt, :tool_name, :tool_input,
                :notification_type, :message, :title, :trigger, :error,
                :is_interrupt, :agent_id, :agent_type

    def self.parse(json_string)
      data = JSON.parse(json_string)
      new(data)
    rescue JSON::ParserError => e
      raise ArgumentError, "invalid JSON: #{e.message}"
    end

    def initialize(data)
      @session_id        = data.fetch("session_id", "")
      @cwd               = data.fetch("cwd", Dir.pwd)
      @transcript_path   = data["transcript_path"]
      @permission_mode   = data["permission_mode"]
      @hook_event_name   = data.fetch("hook_event_name", "")
      @prompt            = data["prompt"]
      @tool_name         = data["tool_name"]
      @notification_type = data["notification_type"]
      @message           = data["message"]
      @title             = data["title"]
      @trigger           = data["trigger"]
      @error             = data["error"]
      @is_interrupt      = data["is_interrupt"]
      @agent_id          = data["agent_id"]
      @agent_type        = data["agent_type"]
      @tool_input        = parse_tool_input(data["tool_input"])
    end

    private

    # Extract only string values from tool_input; skip arrays, numbers, etc.
    def parse_tool_input(raw)
      return nil unless raw.is_a?(Hash)
      raw.each_with_object({}) do |(k, v), acc|
        acc[k] = v if v.is_a?(String)
      end
    end
  end
end
