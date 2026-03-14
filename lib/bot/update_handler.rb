# frozen_string_literal: true

require "logger"
require_relative "../jobs/transcribe_job"

module Bot
  class UpdateHandler
    def initialize(payload)
      @payload = payload
      @message = payload["message"]
      @logger = Logger.new($stdout)
      @logger.formatter = proc { |severity, time, _, msg| "#{time.utc.iso8601} #{severity} [handler] #{msg}\n" }
    end

    def call
      unless @message
        @logger.info("No 'message' key in payload, keys: #{@payload.keys}")
        return
      end

      chat_id = @message.dig("chat", "id")
      chat_type = @message.dig("chat", "type")
      from_id = @message.dig("from", "id")
      msg_id = @message["message_id"]
      @logger.info("Processing message: msg_id=#{msg_id} chat_id=#{chat_id} chat_type=#{chat_type} from=#{from_id}")

      if voice_message?
        @logger.info("Voice message detected")
        if allowed_voice_chat?
          @logger.info("Voice in allowed chat -> handle_voice")
          handle_voice
        else
          @logger.info("Voice in disallowed chat, skipping")
        end
      elsif bot_command?
        @logger.info("Bot command detected: #{@message["text"]}")
        if private_admin_chat?
          handle_command
        else
          @logger.info("Command in non-admin/non-private chat, skipping")
        end
      else
        @logger.info("Message did not match any handler")
      end
    end

    private

    def private_admin_chat?
      @message.dig("chat", "type") == "private" &&
        admin_user?
    end

    def allowed_voice_chat?
      private_admin_chat? || allowed_group_chat?
    end

    def allowed_group_chat?
      allowed_id = ENV["ALLOWED_CHAT_ID"]
      chat_id = @message.dig("chat", "id").to_s
      !allowed_id.to_s.empty? && chat_id == allowed_id.to_s
    end

    def admin_user?
      @message.dig("from", "id").to_s == Config["ADMIN_CHAT_ID"].to_s
    end

    def voice_message?
      @message.key?("voice")
    end

    def bot_command?
      entities = @message["entities"] || []
      entities.any? { |e| e["type"] == "bot_command" }
    end

    def handle_voice
      voice = @message["voice"]
      chat_id = @message["chat"]["id"]
      msg_id = @message["message_id"]
      file_id = voice["file_id"]
      @logger.info("Enqueuing TranscribeJob: chat=#{chat_id} msg=#{msg_id} file=#{file_id}")
      Jobs::TranscribeJob.perform_async(chat_id, msg_id, file_id)
    end

    def handle_command
      text = @message["text"].to_s
      command = text.split(" ").first&.downcase&.split("@")&.first
      user_id = @message.dig("from", "id").to_s
      chat_id = @message["chat"]["id"]

      Bot::CommandHandler.call(command: command, user_id: user_id, chat_id: chat_id)
    end
  end
end
