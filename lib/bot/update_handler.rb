# frozen_string_literal: true

require_relative "../jobs/transcribe_job"

module Bot
  class UpdateHandler
    def initialize(payload)
      @payload = payload
      @message = payload["message"]
    end

    def call
      return unless @message

      if voice_message? && allowed_voice_chat?
        handle_voice
      elsif transcribe_request? && allowed_group_chat?
        handle_transcribe_request
      elsif bot_command? && private_admin_chat?
        handle_command
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
      return false if allowed_id.to_s.empty?

      @message.dig("chat", "id").to_s == allowed_id.to_s
    end

    def admin_user?
      @message.dig("from", "id").to_s == Config["ADMIN_CHAT_ID"].to_s
    end

    def voice_message?
      @message.key?("voice")
    end

    def transcribe_request?
      reply_to = @message.dig("reply_to_message")
      return false unless reply_to&.key?("voice")

      mentions_bot?
    end

    def mentions_bot?
      entities = @message.dig("entities") || []
      text = @message["text"].to_s

      entities.any? do |e|
        e["type"] == "mention" &&
          text[e["offset"], e["length"]]&.downcase&.include?("bot")
      end
    end

    def bot_command?
      entities = @message.dig("entities") || []
      entities.any? { |e| e["type"] == "bot_command" }
    end

    def handle_voice
      voice = @message["voice"]
      Jobs::TranscribeJob.perform_async(
        @message["chat"]["id"],
        @message["message_id"],
        voice["file_id"]
      )
    end

    def handle_transcribe_request
      replied = @message["reply_to_message"]
      Jobs::TranscribeJob.perform_async(
        @message["chat"]["id"],
        replied["message_id"],
        replied["voice"]["file_id"]
      )
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
