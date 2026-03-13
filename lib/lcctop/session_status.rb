module Lcctop
  module SessionStatus
    IDLE               = "idle"
    WORKING            = "working"
    COMPACTING         = "compacting"
    WAITING_PERMISSION = "waiting_permission"
    WAITING_INPUT      = "waiting_input"
    NEEDS_ATTENTION    = "needs_attention"

    ALL = [IDLE, WORKING, COMPACTING, WAITING_PERMISSION, WAITING_INPUT, NEEDS_ATTENTION].freeze

    SORT_ORDER = {
      WAITING_PERMISSION => 0,
      WAITING_INPUT      => 1,
      NEEDS_ATTENTION    => 1,
      WORKING            => 2,
      COMPACTING         => 3,
      IDLE               => 4,
    }.freeze

    def self.sort_order(status)
      SORT_ORDER.fetch(status, 99)
    end

    def self.needs_attention?(status)
      [WAITING_PERMISSION, WAITING_INPUT, NEEDS_ATTENTION].include?(status)
    end

    # Parse a raw string from JSON, tolerating unknown values.
    def self.parse(raw)
      return raw if ALL.include?(raw)
      raw.include?("waiting") ? NEEDS_ATTENTION : WORKING
    end
  end
end
