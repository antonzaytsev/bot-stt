# frozen_string_literal: true

require "sidekiq/api"
require_relative "telegram_client"
require_relative "stats"
require_relative "settings"

module Bot
  class CommandHandler
    COMMANDS = {
      "/start" => :cmd_start,
      "/ping" => :cmd_ping,
      "/status" => :cmd_status,
      "/stats" => :cmd_stats,
      "/settings" => :cmd_settings,
      "/set" => :cmd_set,
      "/help" => :cmd_help
    }.freeze

    MENU = [
      { command: "start", description: "Welcome message with commands and settings" },
      { command: "ping", description: "Liveness check" },
      { command: "status", description: "Bot health, Redis, Sidekiq queue" },
      { command: "stats", description: "Processed/failed counts today" },
      { command: "settings", description: "View bot settings" },
      { command: "set", description: "Change a setting — /set <name> on|off" },
      { command: "help", description: "List available commands" }
    ].freeze

    def self.call(command:, args: [], user_id:, chat_id:)
      new(command: command, args: args, user_id: user_id, chat_id: chat_id).call
    end

    def initialize(command:, args: [], user_id:, chat_id:)
      @command = command
      @args = args
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

    def cmd_start
      lines = [
        "Voice-to-Text Bot",
        "",
        "Commands:",
        "/ping — liveness check",
        "/status — bot health, Redis, Sidekiq queue",
        "/stats — processed/failed counts today",
        "/settings — view bot settings",
        "/set <name> on|off — change a setting",
        "/help — this message",
        ""
      ]
      Settings.all.each do |key, value|
        label = Settings::LABELS[key] || key
        lines << "  #{label}: #{value ? "ON" : "OFF"}"
      end
      reply(lines.join("\n"))
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

    def cmd_settings
      lines = ["Settings:"]
      Settings.all.each do |key, value|
        label = Settings::LABELS[key] || key
        lines << "  #{label}: #{value ? "ON" : "OFF"}"
      end
      lines << ""
      lines << "Use /set <name> on|off"
      lines << "Available: #{Settings::DEFAULTS.keys.join(", ")}"
      reply(lines.join("\n"))
    end

    def cmd_set
      if @args.length < 2
        reply("Usage: /set <setting> on|off\nAvailable: #{Settings::DEFAULTS.keys.join(", ")}")
        return
      end

      key = @args[0]
      value_str = @args[1].downcase

      unless Settings::DEFAULTS.key?(key)
        reply("Unknown setting: #{key}\nAvailable: #{Settings::DEFAULTS.keys.join(", ")}")
        return
      end

      unless %w[on off].include?(value_str)
        reply("Value must be 'on' or 'off'")
        return
      end

      Settings.set(key, value_str == "on")
      label = Settings::LABELS[key] || key
      reply("#{label}: #{value_str.upcase}")
    end

    def cmd_help
      lines = [
        "Available commands:",
        "/ping — liveness check",
        "/status — bot health, Redis, Sidekiq queue",
        "/stats — processed/failed counts today",
        "/settings — view bot settings",
        "/set <name> on|off — change a setting",
        "/help — this message"
      ]
      reply(lines.join("\n"))
    end
  end
end
