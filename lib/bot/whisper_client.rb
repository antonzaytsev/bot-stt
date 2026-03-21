# frozen_string_literal: true

require "net/http"
require "uri"
require "oj"
require "tempfile"

module Bot
  class WhisperClient
    TRANSCRIPTION_URL = "https://api.openai.com/v1/audio/transcriptions"
    CHAT_URL = "https://api.openai.com/v1/chat/completions"

    def initialize(api_key: Config["OPENAI_API_KEY"])
      @api_key = api_key
    end

    def transcribe(audio_data, filename: "voice.ogg", prompt: nil)
      uri = URI(TRANSCRIPTION_URL)
      boundary = "----FormBoundary#{SecureRandom.hex(16)}"

      body = build_multipart_body(boundary, audio_data, filename, prompt: prompt)

      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{@api_key}"
      request["Content-Type"] = "multipart/form-data; boundary=#{boundary}"
      request.body = body

      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 30, read_timeout: 120) do |http|
        http.request(request)
      end

      parsed = Oj.load(response.body)
      raise "Whisper API error: #{parsed.dig("error", "message") || response.code}" unless response.is_a?(Net::HTTPSuccess)

      parsed["text"]
    end

    def format_transcription(text)
      chat_completion(
        "You are a text formatter for speech-to-text output. Your job is to make the transcription easy to read:\n" \
        "- Split into proper sentences with correct punctuation (periods, commas, question marks, etc.)\n" \
        "- Add paragraph breaks when the speaker changes topic or thought\n" \
        "- Fix capitalization at sentence starts\n" \
        "- Remove filler artifacts only if they break readability (keep intentional repetitions)\n" \
        "- Preserve the original language and meaning exactly — do not rephrase, summarize, or add content\n" \
        "- Output ONLY the formatted text, nothing else",
        text
      )
    end

    def improve_transcription(original_text, retranscribed_text)
      chat_completion(
        "You are a speech-to-text post-processor. You receive two transcription attempts of the same audio. " \
        "Produce the single best transcription:\n" \
        "- Fix misheard words by cross-referencing both attempts\n" \
        "- Split into proper sentences with correct punctuation\n" \
        "- Add paragraph breaks when the topic or thought changes\n" \
        "- Fix capitalization\n" \
        "- Preserve the original language and meaning — do not rephrase or summarize\n" \
        "- Output ONLY the corrected text, nothing else",
        "First attempt:\n#{original_text}\n\nSecond attempt:\n#{retranscribed_text}"
      )
    end

    private

    def chat_completion(system_prompt, user_content)
      uri = URI(CHAT_URL)
      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{@api_key}"
      request["Content-Type"] = "application/json"
      request.body = Oj.dump({
        model: "gpt-4o-mini",
        temperature: 0.3,
        messages: [
          { role: "system", content: system_prompt },
          { role: "user", content: user_content }
        ]
      })

      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 30, read_timeout: 60) do |http|
        http.request(request)
      end

      parsed = Oj.load(response.body)
      raise "OpenAI API error: #{parsed.dig("error", "message") || response.code}" unless response.is_a?(Net::HTTPSuccess)

      parsed.dig("choices", 0, "message", "content")&.strip
    end

    def build_multipart_body(boundary, audio_data, filename, prompt: nil)
      parts = []
      parts << "--#{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"#{filename}\"\r\nContent-Type: audio/ogg\r\n\r\n#{audio_data}\r\n"
      parts << "--#{boundary}\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\ngpt-4o-transcribe\r\n"
      if prompt
        parts << "--#{boundary}\r\nContent-Disposition: form-data; name=\"prompt\"\r\n\r\n#{prompt}\r\n"
      end
      parts << "--#{boundary}--\r\n"
      parts.join
    end
  end
end
