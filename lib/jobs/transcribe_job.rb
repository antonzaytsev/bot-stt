# frozen_string_literal: true

require "sidekiq"
require_relative "../bot/telegram_client"
require_relative "../bot/whisper_client"
require_relative "../bot/stats"

module Jobs
  class TranscribeJob
    include Sidekiq::Job

    sidekiq_options retry: 2

    sidekiq_retries_exhausted do |job, ex|
      admin_id = Config["ADMIN_CHAT_ID"]
      chat_id, message_id, = job["args"]
      Bot::TelegramClient.new.send_message(
        chat_id: admin_id,
        text: "Transcription permanently failed after retries\nChat: #{chat_id}\nMessage: #{message_id}\nError: #{ex.class}: #{ex.message}"
      )
    rescue => e
      Sidekiq.logger.error("Failed to notify admin on retries exhausted: #{e.message}")
    end

    def perform(chat_id, message_id, file_id)
      telegram = Bot::TelegramClient.new
      whisper = Bot::WhisperClient.new

      Sidekiq.logger.info("Transcribing: chat=#{chat_id} msg=#{message_id} file=#{file_id}")

      file_info = telegram.get_file(file_id: file_id)
      audio_data = telegram.download_file(file_path: file_info["file_path"])

      text = whisper.transcribe(audio_data)
      telegram.reply_to_message(chat_id: chat_id, message_id: message_id, text: text)

      Bot::Stats.record_success!
      Sidekiq.logger.info("Transcription successful: chat=#{chat_id} msg=#{message_id}")
    rescue => e
      Bot::Stats.record_failure!
      notify_admin(e, chat_id, message_id)
      raise
    end

    private

    def notify_admin(error, chat_id, message_id)
      category = error_category(error)
      admin_id = Config["ADMIN_CHAT_ID"]
      Bot::TelegramClient.new.send_message(
        chat_id: admin_id,
        text: "Transcription failed [#{category}]\nChat: #{chat_id}\nMessage: #{message_id}\nError: #{error.class}: #{error.message}"
      )
    rescue => e
      Sidekiq.logger.error("Failed to notify admin: #{e.message}")
    end

    def error_category(error)
      case error.message
      when /Telegram/i then "Telegram API"
      when /Whisper|OpenAI/i then "OpenAI API"
      when /timeout|Errno::ETIMEDOUT/i then "Network timeout"
      else "Unknown"
      end
    end
  end
end
