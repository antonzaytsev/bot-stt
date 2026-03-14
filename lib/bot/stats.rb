# frozen_string_literal: true

require "date"

module Bot
  module Stats
    @boot_time = Time.now
    @processed = 0
    @failed = 0
    @last_reset_date = Date.today

    class << self
      attr_reader :boot_time, :processed, :failed

      def record_success!
        reset_if_new_day!
        @processed += 1
      end

      def record_failure!
        reset_if_new_day!
        @failed += 1
      end

      def uptime
        (Time.now - @boot_time).to_i
      end

      def uptime_human
        secs = uptime
        days = secs / 86_400
        hours = (secs % 86_400) / 3600
        mins = (secs % 3600) / 60
        parts = []
        parts << "#{days}d" if days > 0
        parts << "#{hours}h" if hours > 0
        parts << "#{mins}m" if mins > 0
        parts << "#{secs % 60}s"
        parts.join(" ")
      end

      private

      def reset_if_new_day!
        today = Date.today
        if today != @last_reset_date
          @processed = 0
          @failed = 0
          @last_reset_date = today
        end
      end
    end
  end
end
