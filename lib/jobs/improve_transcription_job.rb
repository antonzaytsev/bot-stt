# frozen_string_literal: true

require "sidekiq"
require "oj"
require_relative "../bot/telegram_client"
require_relative "../bot/whisper_client"

module Jobs
  class ImproveTranscriptionJob
    include Sidekiq::Job

    sidekiq_options retry: 1

    IMPROVE_COOLDOWN = 60 # seconds between improvement attempts

    def perform(chat_id, bot_message_id)
      Sidekiq.logger.info("[improve] START: chat=#{chat_id} bot_msg=#{bot_message_id}")

      cooldown_key = "improve_cooldown:#{chat_id}:#{bot_message_id}"
      if Sidekiq.redis { |c| c.call("EXISTS", cooldown_key) == 1 }
        Sidekiq.logger.info("[improve] Cooldown active, skipping")
        return
      end

      meta_key = "transcription_meta:#{chat_id}:#{bot_message_id}"
      raw = Sidekiq.redis { |c| c.call("GET", meta_key) }
      unless raw
        Sidekiq.logger.info("[improve] No metadata found for bot_msg=#{bot_message_id}, skipping")
        return
      end

      meta = Oj.load(raw)
      file_id = meta["file_id"]
      original_text = meta["text"]
      Sidekiq.logger.info("[improve] Original text (#{original_text.length} chars), file=#{file_id}")

      telegram = Bot::TelegramClient.new
      whisper = Bot::WhisperClient.new

      Sidekiq.logger.info("[improve] Re-transcribing with original as prompt context...")
      file_info = telegram.get_file(file_id: file_id)
      audio_data = telegram.download_file(file_path: file_info["file_path"])
      retranscribed = whisper.transcribe(audio_data, prompt: original_text)
      Sidekiq.logger.info("[improve] Re-transcription (#{retranscribed.length} chars): #{retranscribed[0..100]}...")

      Sidekiq.logger.info("[improve] Sending to GPT for improvement...")
      improved = whisper.improve_transcription(original_text, retranscribed)
      Sidekiq.logger.info("[improve] Improved (#{improved.length} chars): #{improved[0..100]}...")

      if improved == original_text
        Sidekiq.logger.info("[improve] No improvement found, keeping original")
        return
      end

      Sidekiq.logger.info("[improve] Editing message #{bot_message_id}")
      telegram.edit_message_text(chat_id: chat_id, message_id: bot_message_id, text: improved)

      Sidekiq.redis { |c| c.call("SET", meta_key, Oj.dump({ "file_id" => file_id, "text" => improved }), "EX", 30 * 24 * 3600) }
      Sidekiq.redis { |c| c.call("SET", cooldown_key, "1", "EX", IMPROVE_COOLDOWN) }

      Sidekiq.logger.info("[improve] DONE: chat=#{chat_id} bot_msg=#{bot_message_id}")
    rescue => e
      Sidekiq.logger.error("[improve] FAILED: #{e.class}: #{e.message}")
      Sidekiq.logger.error("[improve] #{e.backtrace&.first(5)&.join("\n")}")
      raise
    end
  end
end
