# frozen_string_literal: true

require "logger"
require_relative "callback_handler"
require_relative "../jobs/transcribe_job"
require_relative "../jobs/transcribe_audio_job"
require_relative "../jobs/transcribe_media_job"
require_relative "../jobs/improve_transcription_job"

module Bot
  class UpdateHandler
    THUMBS_DOWN = "\u{1F44E}"

    # Used when a client uploads audio as a document without an audio mime type.
    AUDIO_EXTENSIONS = %w[mp3 m4a mp4a wav ogg oga opus flac aac wma amr aiff aif].freeze

    # Only YouTube links are picked up unprompted; every other site goes through
    # /summarize <url> so the bot does not react to every link in a group.
    YOUTUBE_RE = %r{https?://(?:[\w-]+\.)*(?:youtube\.com/(?:watch\?|shorts/|live/|embed/)\S*|youtu\.be/[\w-]{5,})}i

    def initialize(payload)
      @payload = payload
      @message = payload["message"]
      @reaction = payload["message_reaction"]
      @callback_query = payload["callback_query"]
      @logger = Logger.new($stdout)
      @logger.formatter = proc { |severity, time, _, msg| "#{time.utc.iso8601} #{severity} [handler] #{msg}\n" }
    end

    def call
      if @callback_query
        Bot::CallbackHandler.new(@callback_query).call
      elsif @reaction
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
      elsif audio_upload?
        @logger.info("Audio upload detected")
        if allowed_voice_chat?
          @logger.info("Audio in allowed chat -> handle_audio")
          handle_audio
        else
          @logger.info("Audio in disallowed chat, skipping")
        end
      elsif bot_command?
        @logger.info("Bot command detected: #{@message["text"]}")
        if private_admin_chat?
          handle_command
        else
          @logger.info("Command in non-admin/non-private chat, skipping")
        end
      elsif (url = media_link)
        @logger.info("Media link detected: #{url}")
        if allowed_voice_chat?
          handle_media_link(url)
        else
          @logger.info("Media link in disallowed chat, skipping")
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

    def audio_upload?
      @message.key?("audio") || audio_document?
    end

    def audio_document?
      document = @message["document"]
      return false unless document
      return true if document["mime_type"].to_s.start_with?("audio/")

      extension = File.extname(document["file_name"].to_s).delete_prefix(".").downcase
      AUDIO_EXTENSIONS.include?(extension)
    end

    def bot_command?
      entities = @message["entities"] || []
      entities.any? { |e| e["type"] == "bot_command" }
    end

    # Matches a link written as plain text as well as one hidden behind a
    # text_link entity, and picks the first YouTube URL out of a longer message.
    def media_link
      candidates = [@message["text"], @message["caption"]].compact
      entities = (@message["entities"] || []) + (@message["caption_entities"] || [])
      candidates += entities.filter_map { |e| e["url"] }

      candidates.filter_map { |candidate| candidate[YOUTUBE_RE] }.first
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

    def handle_audio
      media = @message["audio"] || @message["document"]
      chat_id = @message["chat"]["id"]
      msg_id = @message["message_id"]
      file_id = media["file_id"]
      @logger.info("Enqueuing TranscribeAudioJob: chat=#{chat_id} msg=#{msg_id} file=#{file_id} name=#{media["file_name"]} size=#{media["file_size"]}")
      Jobs::TranscribeAudioJob.perform_async(
        chat_id, msg_id, file_id, media["duration"], media["file_name"], media["file_size"]
      )
    end

    def handle_media_link(url)
      chat_id = @message["chat"]["id"]
      msg_id = @message["message_id"]
      @logger.info("Enqueuing TranscribeMediaJob: chat=#{chat_id} msg=#{msg_id} url=#{url}")
      Jobs::TranscribeMediaJob.perform_async(chat_id, msg_id, url, false)
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
