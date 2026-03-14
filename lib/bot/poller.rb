# frozen_string_literal: true

require "logger"
require_relative "telegram_client"
require_relative "update_handler"

module Bot
  class Poller
    POLL_TIMEOUT = 30

    def initialize
      @telegram = TelegramClient.new
      @offset = nil
      @running = true
      @logger = Logger.new($stdout)
      @logger.formatter = proc { |severity, time, _, msg| "#{time.utc.iso8601} #{severity} [poller] #{msg}\n" }
    end

    def run
      @logger.info("Starting poller...")
      @telegram.delete_webhook
      @logger.info("Webhook cleared, polling for updates")

      trap("INT") { stop }
      trap("TERM") { stop }

      poll_loop
    end

    private

    def stop
      @logger.info("Shutting down poller...")
      @running = false
    end

    def poll_loop
      while @running
        begin
          updates = @telegram.get_updates(offset: @offset, timeout: POLL_TIMEOUT)

          updates.each do |update|
            @offset = update["update_id"] + 1
            process_update(update)
          end
        rescue => e
          @logger.error("Polling error: #{e.class}: #{e.message}")
          sleep 3 if @running
        end
      end
    end

    def process_update(update)
      @logger.info("Update received: update_id=#{update["update_id"]}")
      UpdateHandler.new(update).call
    rescue => e
      @logger.error("Failed to process update #{update["update_id"]}: #{e.class}: #{e.message}")
    end
  end
end
