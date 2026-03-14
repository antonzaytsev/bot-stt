# frozen_string_literal: true

require "sidekiq"

module Bot
  module Settings
    REDIS_PREFIX = "bot:settings:"

    DEFAULTS = {
      "notify_voice" => false
    }.freeze

    LABELS = {
      "notify_voice" => "Notify on voice processing"
    }.freeze

    class << self
      def get(key)
        raw = Sidekiq.redis { |c| c.call("GET", "#{REDIS_PREFIX}#{key}") }
        return DEFAULTS[key.to_s] if raw.nil?
        raw == "1"
      end

      def set(key, value)
        return false unless DEFAULTS.key?(key.to_s)
        Sidekiq.redis { |c| c.call("SET", "#{REDIS_PREFIX}#{key}", value ? "1" : "0") }
        true
      end

      def all
        DEFAULTS.each_with_object({}) do |(key, _), result|
          result[key] = get(key)
        end
      end
    end
  end
end
