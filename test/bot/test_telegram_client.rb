# frozen_string_literal: true

require_relative "../test_helper"

class TestTelegramClient < Minitest::Test
  def setup
    @client = Bot::TelegramClient.new(token: "test-bot-token")
  end

  def test_send_message
    stub_request(:post, "#{TELEGRAM_API}/sendMessage")
      .to_return(status: 200, body: Oj.dump({ "ok" => true, "result" => { "message_id" => 1 } }))

    result = @client.send_message(chat_id: 123, text: "hello")

    assert_equal 1, result["message_id"]
    assert_requested(:post, "#{TELEGRAM_API}/sendMessage") { |req|
      body = Oj.load(req.body)
      body["chat_id"] == 123 && body["text"] == "hello"
    }
  end

  def test_send_message_with_parse_mode
    stub_request(:post, "#{TELEGRAM_API}/sendMessage")
      .to_return(status: 200, body: Oj.dump({ "ok" => true, "result" => {} }))

    @client.send_message(chat_id: 123, text: "hello", parse_mode: "HTML")

    assert_requested(:post, "#{TELEGRAM_API}/sendMessage") { |req|
      body = Oj.load(req.body)
      body["parse_mode"] == "HTML"
    }
  end

  def test_reply_to_message
    stub_request(:post, "#{TELEGRAM_API}/sendMessage")
      .to_return(status: 200, body: Oj.dump({ "ok" => true, "result" => {} }))

    @client.reply_to_message(chat_id: 123, message_id: 42, text: "reply")

    assert_requested(:post, "#{TELEGRAM_API}/sendMessage") { |req|
      body = Oj.load(req.body)
      body["reply_to_message_id"] == 42
    }
  end

  def test_get_file
    stub_request(:post, "#{TELEGRAM_API}/getFile")
      .to_return(status: 200, body: Oj.dump({ "ok" => true, "result" => { "file_path" => "voice/file.ogg" } }))

    result = @client.get_file(file_id: "abc")
    assert_equal "voice/file.ogg", result["file_path"]
  end

  def test_download_file
    stub_request(:get, "https://api.telegram.org/file/bottest-bot-token/voice/file.ogg")
      .to_return(status: 200, body: "audio-bytes")

    result = @client.download_file(file_path: "voice/file.ogg")
    assert_equal "audio-bytes", result
  end

  def test_download_file_raises_on_failure
    stub_request(:get, "https://api.telegram.org/file/bottest-bot-token/voice/file.ogg")
      .to_return(status: 404, body: "Not Found")

    assert_raises(RuntimeError) { @client.download_file(file_path: "voice/file.ogg") }
  end

  def test_get_updates
    updates = [{ "update_id" => 1, "message" => {} }]
    stub_request(:post, "#{TELEGRAM_API}/getUpdates")
      .to_return(status: 200, body: Oj.dump({ "ok" => true, "result" => updates }))

    result = @client.get_updates(offset: 1, timeout: 10)

    assert_equal 1, result.length
    assert_requested(:post, "#{TELEGRAM_API}/getUpdates") { |req|
      body = Oj.load(req.body)
      body["offset"] == 1 && body["timeout"] == 10
    }
  end

  def test_delete_webhook
    stub_request(:post, "#{TELEGRAM_API}/deleteWebhook")
      .to_return(status: 200, body: Oj.dump({ "ok" => true, "result" => true }))

    result = @client.delete_webhook
    assert_equal true, result
  end

  def test_raises_on_api_error
    stub_request(:post, "#{TELEGRAM_API}/sendMessage")
      .to_return(status: 400, body: Oj.dump({ "ok" => false, "description" => "Bad Request: chat not found" }))

    error = assert_raises(RuntimeError) { @client.send_message(chat_id: 123, text: "hello") }
    assert_match(/Bad Request/, error.message)
  end
end
