# frozen_string_literal: true

require "logger"
require_relative "../jobs/transcribe_job"
require_relative "../jobs/improve_transcription_job"

module Bot
  class UpdateHandler
    THUMBS_DOWN = "\u{1F44E}"

    def initialize(payload)
      @payload = payload
      @message = payload["message"]
      @reaction = payload["message_reaction"]
      @logger = Logger.new($stdout)
      @logger.formatter = proc { |severity, time, _, msg| "#{time.utc.iso8601} #{severity} [handler] #{msg}\n" }
    end

    def call
      if @reaction
        handle_reaction
      elsif @message
        handle_message
      else
        @logger.info("Unhandled update, keys: #{@payload.keys}")
      end
    end

    def handle_message
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

    def handle_reaction
      chat_id = @reaction.dig("chat", "id")
      msg_id = @reaction["message_id"]
      new_reactions = @reaction["new_reaction"] || []
      has_thumbs_down = new_reactions.any? { |r| r["type"] == "emoji" && r["emoji"] == THUMBS_DOWN }

      @logger.info("Reaction on msg=#{msg_id} chat=#{chat_id} thumbs_down=#{has_thumbs_down}")
      return unless has_thumbs_down

      @logger.info("Thumbs down detected -> enqueuing ImproveTranscriptionJob")
      Jobs::ImproveTranscriptionJob.perform_async(chat_id, msg_id)
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
      duration = voice["duration"]
      @logger.info("Enqueuing TranscribeJob: chat=#{chat_id} msg=#{msg_id} file=#{file_id} duration=#{duration}")
      Jobs::TranscribeJob.perform_async(chat_id, msg_id, file_id, duration)
    end

    def handle_command
      text = @message["text"].to_s
      parts = text.split(" ")
      command = parts.first&.downcase&.split("@")&.first
      args = parts[1..] || []
      user_id = @message.dig("from", "id").to_s
      chat_id = @message["chat"]["id"]

      Bot::CommandHandler.call(command: command, args: args, user_id: user_id, chat_id: chat_id)
    end
  end
end
