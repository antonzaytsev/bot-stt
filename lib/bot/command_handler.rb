# frozen_string_literal: true

require "sidekiq/api"
require_relative "telegram_client"
require_relative "stats"

module Bot
  class CommandHandler
    COMMANDS = {
      "/ping" => :cmd_ping,
      "/status" => :cmd_status,
      "/stats" => :cmd_stats,
      "/help" => :cmd_help
    }.freeze

    def self.call(command:, user_id:, chat_id:)
      new(command: command, user_id: user_id, chat_id: chat_id).call
    end

    def initialize(command:, user_id:, chat_id:)
      @command = command
      @user_id = user_id
      @chat_id = chat_id
      @telegram = TelegramClient.new
    end

    def call
      return unless admin?
      return unless COMMANDS.key?(@command)

      send(COMMANDS[@command])
    end

    private

    def admin?
      @user_id.to_s == Config["ADMIN_CHAT_ID"].to_s
    end

    def reply(text)
      @telegram.send_message(chat_id: @user_id, text: text)
    end

    def cmd_ping
      reply("pong")
    end

    def cmd_status
      redis_ok = begin
        Sidekiq.redis { |c| c.call("PING") } == "PONG"
      rescue
        false
      end

      queue = Sidekiq::Queue.new
      lines = [
        "Uptime: #{Stats.uptime_human}",
        "Redis: #{redis_ok ? "connected" : "UNREACHABLE"}",
        "Sidekiq queue size: #{queue.size}",
        "Sidekiq retry set: #{Sidekiq::RetrySet.new.size}"
      ]
      reply(lines.join("\n"))
    end

    def cmd_stats
      lines = [
        "Today's stats:",
        "  Processed: #{Stats.processed}",
        "  Failed: #{Stats.failed}"
      ]
      reply(lines.join("\n"))
    end

    def cmd_help
      lines = [
        "Available commands:",
        "/ping — liveness check",
        "/status — bot health, Redis, Sidekiq queue",
        "/stats — processed/failed counts today",
        "/help — this message"
      ]
      reply(lines.join("\n"))
    end
  end
end
