# frozen_string_literal: true

require "httpx"
require "oj"
require "tempfile"

module Bot
  class WhisperClient
    API_URL = "https://api.openai.com/v1/audio/transcriptions"

    def initialize(api_key: Config["OPENAI_API_KEY"])
      @api_key = api_key
      @http = HTTPX.with(
        timeout: { operation_timeout: 120 },
        headers: { "Authorization" => "Bearer #{@api_key}" }
      )
    end

    def transcribe(audio_data, filename: "voice.ogg")
      tempfile = Tempfile.new(["voice", File.extname(filename)])
      tempfile.binmode
      tempfile.write(audio_data)
      tempfile.rewind

      response = @http.plugin(:multipart).post(
        API_URL,
        form: {
          file: { content_type: "audio/ogg", filename: filename, body: tempfile.read },
          model: "whisper-1"
        }
      )

      tempfile.close
      tempfile.unlink

      body = Oj.load(response.body.to_s)
      raise "Whisper API error: #{body["error"]&.dig("message") || response.status}" unless response.status == 200

      body["text"]
    end
  end
end
