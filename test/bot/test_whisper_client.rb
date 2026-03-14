# frozen_string_literal: true

require_relative "../test_helper"

class TestWhisperClient < Minitest::Test
  WHISPER_URL = "https://api.openai.com/v1/audio/transcriptions"

  def setup
    @client = Bot::WhisperClient.new(api_key: "test-openai-key")
  end

  def test_transcribe_returns_text
    stub_request(:post, WHISPER_URL)
      .to_return(status: 200, body: Oj.dump({ "text" => "Hello world" }))

    result = @client.transcribe("fake-audio-data")
    assert_equal "Hello world", result
  end

  def test_transcribe_sends_authorization_header
    stub_request(:post, WHISPER_URL)
      .to_return(status: 200, body: Oj.dump({ "text" => "ok" }))

    @client.transcribe("data")

    assert_requested(:post, WHISPER_URL) { |req|
      req.headers["Authorization"] == "Bearer test-openai-key"
    }
  end

  def test_transcribe_sends_multipart_form
    stub_request(:post, WHISPER_URL)
      .to_return(status: 200, body: Oj.dump({ "text" => "ok" }))

    @client.transcribe("audio-bytes", filename: "voice.ogg")

    assert_requested(:post, WHISPER_URL) { |req|
      req.headers["Content-Type"].include?("multipart/form-data") &&
        req.body.include?("whisper-1") &&
        req.body.include?("audio-bytes")
    }
  end

  def test_transcribe_raises_on_api_error
    stub_request(:post, WHISPER_URL)
      .to_return(status: 401, body: Oj.dump({ "error" => { "message" => "Invalid API key" } }))

    error = assert_raises(RuntimeError) { @client.transcribe("data") }
    assert_match(/Invalid API key/, error.message)
  end

  def test_transcribe_raises_on_server_error
    stub_request(:post, WHISPER_URL)
      .to_return(status: 500, body: Oj.dump({ "error" => { "message" => "Internal error" } }))

    error = assert_raises(RuntimeError) { @client.transcribe("data") }
    assert_match(/Internal error/, error.message)
  end
end
