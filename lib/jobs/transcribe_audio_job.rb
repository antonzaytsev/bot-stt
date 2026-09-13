# frozen_string_literal: true

require "sidekiq"
require "fileutils"
require "tmpdir"
require_relative "../bot/telegram_client"
require_relative "../bot/whisper_client"
require_relative "../bot/audio_downloader"
require_relative "../bot/stats"
require_relative "../bot/settings"

module Jobs
  # Transcribes uploaded audio — Telegram `audio` messages and audio files sent
  # as `document`. Same pipeline as TranscribeJob (Whisper + LLM formatting),
  # plus ffmpeg normalisation/chunking for long files and a document reply when
  # the transcript does not fit into a Telegram message.
  class TranscribeAudioJob
    include Sidekiq::Job

    sidekiq_options retry: 1

    DEDUP_TTL = 30 * 24 * 3600 # 30 days
    CHUNK_SECONDS = 600
    MAX_TEXT_CHARS = 3500 # Telegram caps messages at 4096
    MAX_DOWNLOAD_BYTES = 20 * 1024 * 1024 # Telegram bot API download limit
    WHISPER_COST_PER_MINUTE = 0.006

    def self.make_downloader
      Bot::AudioDownloader.new
    end

    sidekiq_retries_exhausted do |job, ex|
      admin_id = Config["ADMIN_CHAT_ID"]
      chat_id, message_id, = job["args"]
      Bot::TelegramClient.new.send_message(
        chat_id: admin_id,
        text: "Audio transcription permanently failed after retries\nChat: #{chat_id}\nMessage: #{message_id}\nError: #{ex.class}: #{ex.message}"
      )
    rescue => e
      Sidekiq.logger.error("Failed to notify admin on retries exhausted: #{e.message}")
    end

    def perform(chat_id, message_id, file_id, duration = nil, file_name = nil, file_size = nil)
      Sidekiq.logger.info("[audio] START: chat=#{chat_id} msg=#{message_id} file=#{file_id} name=#{file_name} size=#{file_size}")
      job_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      @chat_id = chat_id
      @message_id = message_id
      @telegram = Bot::TelegramClient.new
      @whisper = Bot::WhisperClient.new

      dedup_key = "transcribed:#{chat_id}:#{message_id}"
      if already_transcribed?(dedup_key)
        Sidekiq.logger.info("[audio] Already transcribed: chat=#{chat_id} msg=#{message_id}, skipping")
        return
      end

      if file_size && file_size > MAX_DOWNLOAD_BYTES
        Sidekiq.logger.info("[audio] File too large: #{file_size} bytes")
        reply("Audio file is too large (#{mb(file_size)} MB). Telegram bots can only download files up to #{mb(MAX_DOWNLOAD_BYTES)} MB.")
        mark_transcribed(dedup_key)
        return
      end

      @status_msg_id = reply("Transcribing audio...")["message_id"]

      tmp_dir = Dir.mktmpdir("audio")
      begin
        update_status("Downloading audio...")
        input_path = download_audio(file_id, file_name, tmp_dir)

        update_status("Preparing audio...")
        chunks = self.class.make_downloader.split_audio(input_path, chunk_seconds: CHUNK_SECONDS, output_dir: tmp_dir)
        Sidekiq.logger.info("[audio] Split into #{chunks.length} chunk(s)")

        raw_parts = transcribe_chunks(chunks)
        final_text = format_parts(raw_parts)
        Sidekiq.logger.info("[audio] Final text (#{final_text.length} chars): #{final_text[0..100]}...")

        deliver(final_text, file_name)
      ensure
        FileUtils.remove_entry(tmp_dir) if File.directory?(tmp_dir)
      end

      mark_transcribed(dedup_key)
      Bot::Stats.record_success!

      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - job_start
      notify_audio_processed(duration, elapsed) if Bot::Settings.get("notify_voice")

      Sidekiq.logger.info("[audio] DONE: chat=#{chat_id} msg=#{message_id}")
    rescue => e
      Sidekiq.logger.error("[audio] FAILED: chat=#{chat_id} msg=#{message_id} error=#{e.class}: #{e.message}")
      Sidekiq.logger.error("[audio] #{e.backtrace&.first(5)&.join("\n")}")
      Bot::Stats.record_failure!
      update_status("Failed: #{e.message}"[0..4000])
      notify_admin(e, chat_id, message_id)
      raise
    end

    private

    def download_audio(file_id, file_name, tmp_dir)
      file_info = @telegram.get_file(file_id: file_id)
      Sidekiq.logger.info("[audio] File info: path=#{file_info["file_path"]} size=#{file_info["file_size"]}")

      audio_data = @telegram.download_file(file_path: file_info["file_path"])
      Sidekiq.logger.info("[audio] Downloaded #{audio_data.bytesize} bytes")

      input_path = File.join(tmp_dir, "input#{extension_for(file_name, file_info["file_path"])}")
      File.binwrite(input_path, audio_data)
      input_path
    end

    # Whisper only accepts a handful of container formats and caps upload size,
    # so every upload goes through ffmpeg — it normalises to opus/ogg and splits
    # long recordings into chunks we can transcribe sequentially.
    def transcribe_chunks(chunks)
      chunks.each_with_index.map do |chunk_path, i|
        update_status("Transcribing chunk #{i + 1}/#{chunks.length}...") if chunks.length > 1
        audio_data = File.read(chunk_path, mode: "rb")
        text = @whisper.transcribe(audio_data, filename: File.basename(chunk_path), prompt: tail_context(@last_part))
        @last_part = text
        text
      end
    end

    def tail_context(text)
      return nil if text.nil? || text.empty?

      text.length > 200 ? text[-200..] : text
    end

    # Formatted per chunk so a long recording never hits the LLM output limit.
    def format_parts(parts)
      parts.each_with_index.map do |text, i|
        update_status("Formatting #{i + 1}/#{parts.length}...") if parts.length > 1
        format_transcription(text)
      end.join("\n\n")
    end

    def format_transcription(text)
      formatted = @whisper.format_transcription(text)
      formatted && !formatted.empty? ? formatted : text
    rescue => e
      Sidekiq.logger.error("[audio] Formatting failed, using raw transcription: #{e.class}: #{e.message}")
      text
    end

    def deliver(text, file_name)
      if text.length <= MAX_TEXT_CHARS
        @telegram.edit_message_text(chat_id: @chat_id, message_id: @status_msg_id, text: text)
        return
      end

      Sidekiq.logger.info("[audio] Transcript too long for a message (#{text.length} chars), sending as file")
      @telegram.send_document(
        chat_id: @chat_id,
        filename: transcript_filename(file_name),
        data: text,
        caption: "Transcript (#{text.length} characters)",
        reply_to_message_id: @message_id
      )
      update_status("Transcript is #{text.length} characters — sent as a file.")
    end

    def transcript_filename(file_name)
      base = File.basename(file_name.to_s, ".*").strip
      base = "transcript" if base.empty?
      "#{base}.txt"
    end

    def extension_for(file_name, telegram_path)
      ext = File.extname(file_name.to_s)
      ext = File.extname(telegram_path.to_s) if ext.empty?
      ext.empty? ? ".bin" : ext.downcase
    end

    def reply(text)
      @telegram.reply_to_message(chat_id: @chat_id, message_id: @message_id, text: text)
    end

    def update_status(text)
      return if @status_msg_id.nil?

      @telegram.edit_message_text(chat_id: @chat_id, message_id: @status_msg_id, text: text)
    rescue => e
      Sidekiq.logger.error("[audio] Failed to update status: #{e.message}")
    end

    def already_transcribed?(key)
      Sidekiq.redis { |c| c.call("EXISTS", key) == 1 }
    end

    def mark_transcribed(key)
      Sidekiq.redis { |c| c.call("SET", key, "1", "EX", DEDUP_TTL) }
    end

    def mb(bytes)
      (bytes / 1024.0 / 1024.0).round(1)
    end

    def notify_audio_processed(duration, elapsed)
      parts = ["Audio transcribed"]
      parts << "Audio: #{duration}s" if duration
      parts << "Time: #{elapsed.round(1)}s"
      if duration
        cost = (duration / 60.0) * WHISPER_COST_PER_MINUTE
        parts << "Cost: $#{"%.4f" % cost}"
      end
      @telegram.send_message(chat_id: Config["ADMIN_CHAT_ID"], text: parts.join(" | "))
    rescue => e
      Sidekiq.logger.error("[audio] Failed to send notification: #{e.message}")
    end

    def notify_admin(error, chat_id, message_id)
      category = error_category(error)
      Bot::TelegramClient.new.send_message(
        chat_id: Config["ADMIN_CHAT_ID"],
        text: "Audio transcription failed [#{category}]\nChat: #{chat_id}\nMessage: #{message_id}\nError: #{error.class}: #{error.message}"
      )
    rescue => e
      Sidekiq.logger.error("[audio] Failed to notify admin: #{e.message}")
    end

    def error_category(error)
      case error.message
      when /Telegram/i then "Telegram API"
      when /Whisper|OpenAI/i then "OpenAI API"
      when /ffmpeg|Command failed/i then "Audio conversion"
      when /timeout|Errno::ETIMEDOUT/i then "Network timeout"
      else "Unknown"
      end
    end
  end
end
