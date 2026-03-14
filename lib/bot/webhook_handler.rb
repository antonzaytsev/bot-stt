# frozen_string_literal: true

require_relative "../jobs/transcribe_job"

module Bot
  class WebhookHandler
    def initialize(payload)
      @payload = payload
      @message = payload["message"]
    end

    def call
      return unless @message

      if voice_message?
        handle_voice
      elsif bot_command?
        handle_command
      end
    end

    private

    def voice_message?
      @message.key?("voice")
    end

    def bot_command?
      entities = @message.dig("entities") || []
      entities.any? { |e| e["type"] == "bot_command" }
    end

    def handle_voice
      Jobs::TranscribeJob.perform_async(
        @message["chat"]["id"],
        @message["message_id"],
        @message["voice"]["file_id"]
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
