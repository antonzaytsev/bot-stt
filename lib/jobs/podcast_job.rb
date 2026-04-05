# frozen_string_literal: true

require "sidekiq"
require "fileutils"
require "tmpdir"
require_relative "../bot/telegram_client"
require_relative "../bot/whisper_client"
require_relative "../bot/audio_downloader"

module Jobs
  class PodcastJob
    include Sidekiq::Job

    sidekiq_options retry: 1, queue: "default"

    CHUNK_SECONDS = 600

    def self.make_downloader
      Bot::AudioDownloader.new
    end

    def perform(chat_id, url)
      @telegram = Bot::TelegramClient.new
      @whisper = Bot::WhisperClient.new
      @chat_id = chat_id

      status = @telegram.send_message(chat_id: chat_id, text: "Downloading podcast...")
      @status_msg_id = status["message_id"]

      tmp_dir = Dir.mktmpdir("podcast")
      begin
        downloader = self.class.make_downloader

        update_status("Downloading audio...")
        audio_path = downloader.download(url, output_dir: tmp_dir)

        update_status("Splitting audio into chunks...")
        chunks = downloader.split_audio(audio_path, chunk_seconds: CHUNK_SECONDS, output_dir: tmp_dir)

        update_status("Transcribing #{chunks.length} chunk(s)...")
        transcript = transcribe_chunks(chunks)

        update_status("Summarizing...")
        summary = @whisper.summarize_podcast(transcript)

        update_status(summary)
      rescue => e
        update_status("Failed: #{e.message}"[0..4000])
        raise
      ensure
        FileUtils.remove_entry(tmp_dir) if File.directory?(tmp_dir)
      end
    end

    private

    def transcribe_chunks(chunks)
      full_text = +""
      chunks.each_with_index do |chunk_path, i|
        update_status("Transcribing chunk #{i + 1}/#{chunks.length}...")
        audio_data = File.read(chunk_path, mode: "rb")
        prompt = full_text.length > 200 ? full_text[-200..] : full_text.empty? ? nil : full_text
        full_text << " " unless full_text.empty?
        full_text << @whisper.transcribe(audio_data, filename: File.basename(chunk_path), prompt: prompt)
      end
      full_text
    end

    def update_status(text)
      @telegram.edit_message_text(chat_id: @chat_id, message_id: @status_msg_id, text: text)
    rescue => e
      Sidekiq.logger.error("[podcast] Failed to update status: #{e.message}")
    end
  end
end
