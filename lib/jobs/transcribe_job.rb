# frozen_string_literal: true

require "sidekiq"
require_relative "../bot/telegram_client"
require_relative "../bot/whisper_client"
require_relative "../bot/stats"

module Jobs
  class TranscribeJob
    include Sidekiq::Job

    sidekiq_options retry: 2

    def perform(chat_id, message_id, file_id)
      telegram = Bot::TelegramClient.new
      whisper = Bot::WhisperClient.new

      file_info = telegram.get_file(file_id: file_id)
      audio_data = telegram.download_file(file_path: file_info["file_path"])

      text = whisper.transcribe(audio_data)
      telegram.reply_to_message(chat_id: chat_id, message_id: message_id, text: text)

      Bot::Stats.record_success!
    rescue => e
      Bot::Stats.record_failure!
      notify_admin(e, chat_id, message_id)
      raise
    end

    private

    def notify_admin(error, chat_id, message_id)
      admin_id = Config["ADMIN_CHAT_ID"]
      telegram = Bot::TelegramClient.new
      telegram.send_message(
        chat_id: admin_id,
        text: "Transcription failed\nChat: #{chat_id}\nMessage: #{message_id}\nError: #{error.class}: #{error.message}"
      )
    rescue => notify_error
      Sidekiq.logger.error("Failed to notify admin: #{notify_error.message}")
    end
  end
end
