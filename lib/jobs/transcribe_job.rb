# frozen_string_literal: true

require "sidekiq"
require_relative "../bot/telegram_client"
require_relative "../bot/whisper_client"
require_relative "../bot/stats"

module Jobs
  class TranscribeJob
    include Sidekiq::Job

    sidekiq_options retry: 2

    DEDUP_TTL = 30 * 24 * 3600 # 30 days

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
      Sidekiq.logger.info("[job] START TranscribeJob: chat=#{chat_id} msg=#{message_id} file=#{file_id}")
      dedup_key = "transcribed:#{chat_id}:#{message_id}"

      if already_transcribed?(dedup_key)
        Sidekiq.logger.info("[job] Already transcribed: chat=#{chat_id} msg=#{message_id}, skipping")
        return
      end

      telegram = Bot::TelegramClient.new
      whisper = Bot::WhisperClient.new

      Sidekiq.logger.info("[job] Getting file info for file_id=#{file_id}")
      file_info = telegram.get_file(file_id: file_id)
      Sidekiq.logger.info("[job] File info: path=#{file_info["file_path"]} size=#{file_info["file_size"]}")

      Sidekiq.logger.info("[job] Downloading audio...")
      audio_data = telegram.download_file(file_path: file_info["file_path"])
      Sidekiq.logger.info("[job] Downloaded #{audio_data.bytesize} bytes")

      Sidekiq.logger.info("[job] Sending to Whisper API...")
      text = whisper.transcribe(audio_data)
      Sidekiq.logger.info("[job] Whisper response (#{text.length} chars): #{text[0..100]}...")

      Sidekiq.logger.info("[job] Sending reply to chat=#{chat_id} reply_to=#{message_id}")
      telegram.reply_to_message(chat_id: chat_id, message_id: message_id, text: text)

      mark_transcribed(dedup_key)
      Bot::Stats.record_success!
      Sidekiq.logger.info("[job] DONE TranscribeJob: chat=#{chat_id} msg=#{message_id}")
    rescue => e
      Sidekiq.logger.error("[job] FAILED TranscribeJob: chat=#{chat_id} msg=#{message_id} error=#{e.class}: #{e.message}")
      Sidekiq.logger.error("[job] #{e.backtrace&.first(5)&.join("\n")}")
      Bot::Stats.record_failure!
      notify_admin(e, chat_id, message_id)
      raise
    end

    private

    def already_transcribed?(key)
      Sidekiq.redis { |c| c.call("EXISTS", key) == 1 }
    end

    def mark_transcribed(key)
      Sidekiq.redis { |c| c.call("SET", key, "1", "EX", DEDUP_TTL) }
    end

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
