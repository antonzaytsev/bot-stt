# frozen_string_literal: true

require "net/http"
require "uri"
require "oj"
require "tempfile"

module Bot
  class WhisperClient
    API_URL = "https://api.openai.com/v1/audio/transcriptions"

    def initialize(api_key: Config["OPENAI_API_KEY"])
      @api_key = api_key
    end

    def transcribe(audio_data, filename: "voice.ogg")
      uri = URI(API_URL)
      boundary = "----FormBoundary#{SecureRandom.hex(16)}"

      body = build_multipart_body(boundary, audio_data, filename)

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

    private

    def build_multipart_body(boundary, audio_data, filename)
      parts = []
      parts << "--#{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"#{filename}\"\r\nContent-Type: audio/ogg\r\n\r\n#{audio_data}\r\n"
      parts << "--#{boundary}\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-1\r\n"
      parts << "--#{boundary}--\r\n"
      parts.join
    end
  end
end
