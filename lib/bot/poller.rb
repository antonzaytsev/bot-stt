# frozen_string_literal: true

require "logger"
require "json"
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
      register_commands
      notify_admin("Bot started")

      trap("INT") { stop }
      trap("TERM") { stop }

      poll_loop
      notify_admin("Bot stopped")
    end

    private

    def stop
      @logger.info("Shutting down poller...")
      @running = false
    end

    def notify_admin(text)
      @telegram.send_message(chat_id: Config["ADMIN_CHAT_ID"], text: text)
      @logger.info("Admin notified: #{text}")
    rescue => e
      @logger.error("Failed to notify admin: #{e.message}")
    end

    def register_commands
      @telegram.set_my_commands(CommandHandler::MENU)
      @logger.info("Bot command menu registered")
    rescue => e
      @logger.error("Failed to register command menu: #{e.message}")
    end

    def poll_loop
      while @running
        begin
          updates = @telegram.get_updates(offset: @offset, timeout: POLL_TIMEOUT)
          @logger.info("Received #{updates.size} update(s)") if updates.any?

          updates.each do |update|
            @offset = update["update_id"] + 1
            process_update(update)
          end
        rescue => e
          @logger.error("Polling error: #{e.class}: #{e.message}")
          @logger.error(e.backtrace&.first(5)&.join("\n"))
          sleep 3 if @running
        end
      end
    end

    def process_update(update)
      @logger.info("--- Update id=#{update["update_id"]} ---")

      if update["message"]
        msg = update["message"]
        chat = msg.dig("chat")
        @logger.info("  [message] chat_id=#{chat&.dig("id")} type=#{chat&.dig("type")} has_voice=#{msg.key?("voice")} text=#{msg.dig("text").inspect}")
      elsif update["message_reaction"]
        reaction = update["message_reaction"]
        @logger.info("  [reaction] chat_id=#{reaction.dig("chat", "id")} msg_id=#{reaction["message_id"]} new=#{reaction["new_reaction"]}")
      else
        @logger.info("  [unknown] keys=#{update.keys}")
      end

      UpdateHandler.new(update).call
    rescue => e
      @logger.error("Failed to process update #{update["update_id"]}: #{e.class}: #{e.message}")
      @logger.error(e.backtrace&.first(5)&.join("\n"))
    end
  end
end
