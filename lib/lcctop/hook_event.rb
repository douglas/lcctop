module Lcctop
  module HookEvent
    SESSION_START         = :session_start
    USER_PROMPT_SUBMIT    = :user_prompt_submit
    PRE_TOOL_USE          = :pre_tool_use
    POST_TOOL_USE         = :post_tool_use
    POST_TOOL_USE_FAILURE = :post_tool_use_failure
    STOP                  = :stop
    NOTIFICATION_IDLE     = :notification_idle
    NOTIFICATION_PERMISSION = :notification_permission
    NOTIFICATION_OTHER    = :notification_other
    PERMISSION_REQUEST    = :permission_request
    SUBAGENT_START        = :subagent_start
    SUBAGENT_STOP         = :subagent_stop
    PRE_COMPACT           = :pre_compact
    POST_COMPACT          = :post_compact
    SESSION_ERROR         = :session_error
    SESSION_END           = :session_end
    UNKNOWN               = :unknown

    HOOK_NAME_MAP = {
      "SessionStart"        => SESSION_START,
      "UserPromptSubmit"    => USER_PROMPT_SUBMIT,
      "PreToolUse"          => PRE_TOOL_USE,
      "PostToolUse"         => POST_TOOL_USE,
      "PostToolUseFailure"  => POST_TOOL_USE_FAILURE,
      "Stop"                => STOP,
      "PermissionRequest"   => PERMISSION_REQUEST,
      "PreCompact"          => PRE_COMPACT,
      "PostCompact"         => POST_COMPACT,
      "SubagentStart"       => SUBAGENT_START,
      "SubagentStop"        => SUBAGENT_STOP,
      "SessionError"        => SESSION_ERROR,
      "SessionEnd"          => SESSION_END,
    }.freeze

    def self.parse(hook_name, notification_type: nil)
      if hook_name == "Notification"
        case notification_type
        when "idle_prompt", "elicitation_dialog" then NOTIFICATION_IDLE
        when "permission_prompt" then NOTIFICATION_PERMISSION
        else NOTIFICATION_OTHER
        end
      else
        HOOK_NAME_MAP.fetch(hook_name, UNKNOWN)
      end
    end
  end

  module Transition
    # Returns nil to mean "preserve current status".
    def self.for_event(current_status, event)
      case event
      when HookEvent::SESSION_START                                  then SessionStatus::IDLE
      when HookEvent::STOP                                           then SessionStatus::WAITING_INPUT
      when HookEvent::USER_PROMPT_SUBMIT,
           HookEvent::PRE_TOOL_USE,
           HookEvent::POST_TOOL_USE,
           HookEvent::POST_TOOL_USE_FAILURE                         then SessionStatus::WORKING
      when HookEvent::NOTIFICATION_IDLE                             then SessionStatus::WAITING_INPUT
      when HookEvent::PERMISSION_REQUEST                            then SessionStatus::WAITING_PERMISSION
      when HookEvent::PRE_COMPACT                                   then SessionStatus::COMPACTING
      when HookEvent::POST_COMPACT                                   then SessionStatus::IDLE
      when HookEvent::SESSION_ERROR                                  then SessionStatus::NEEDS_ATTENTION
      when HookEvent::SUBAGENT_START, HookEvent::SUBAGENT_STOP     then nil
      when HookEvent::NOTIFICATION_PERMISSION,
           HookEvent::NOTIFICATION_OTHER,
           HookEvent::SESSION_END,
           HookEvent::UNKNOWN                                        then nil
      end
    end
  end
end
