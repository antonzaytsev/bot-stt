# frozen_string_literal: true

require "sidekiq"
require_relative "whisper_client"

module Bot
  # Turns a list of audio chunks into finished text: each chunk is transcribed
  # with the tail of the previous one as prompt context, then formatted
  # separately so a long recording never hits the LLM output limit.
  #
  # Shared by every source that produces chunks — uploaded audio and media URLs.
  class ChunkedTranscriber
    CONTEXT_CHARS = 200

    def initialize(whisper: WhisperClient.new, progress: nil)
      @whisper = whisper
      @progress = progress
    end

    # Returns { parts: [raw chunk transcripts], text: formatted transcript }
    def call(chunk_paths)
      parts = transcribe(chunk_paths)
      { parts: parts, text: format_parts(parts) }
    end

    private

    def transcribe(chunk_paths)
      previous = nil
      chunk_paths.each_with_index.map do |chunk_path, i|
        report("Transcribing chunk #{i + 1}/#{chunk_paths.length}...") if chunk_paths.length > 1
        audio_data = File.read(chunk_path, mode: "rb")
        text = @whisper.transcribe(audio_data, filename: File.basename(chunk_path), prompt: tail_context(previous))
        previous = text
        text
      end
    end

    def format_parts(parts)
      parts.each_with_index.map do |text, i|
        report("Formatting #{i + 1}/#{parts.length}...") if parts.length > 1
        format_transcription(text)
      end.join("\n\n")
    end

    def format_transcription(text)
      formatted = @whisper.format_transcription(text)
      formatted && !formatted.empty? ? formatted : text
    rescue => e
      Sidekiq.logger.error("[transcriber] Formatting failed, using raw transcription: #{e.class}: #{e.message}")
      text
    end

    def tail_context(text)
      return nil if text.nil? || text.empty?

      text.length > CONTEXT_CHARS ? text[-CONTEXT_CHARS..] : text
    end

    def report(message)
      @progress&.call(message)
    end
  end
end
