# frozen_string_literal: true

require_relative "../test_helper"

class TestWebhookHandler < Minitest::Test
  def setup
    Sidekiq::Worker.clear_all
  end

  def test_enqueues_transcribe_job_for_voice_message
    payload = {
      "message" => {
        "message_id" => 42,
        "chat" => { "id" => -1001234 },
        "from" => { "id" => 999 },
        "voice" => { "file_id" => "abc123", "duration" => 5 }
      }
    }

    Bot::WebhookHandler.new(payload).call

    assert_equal 1, Jobs::TranscribeJob.jobs.size
    job = Jobs::TranscribeJob.jobs.first
    assert_equal [-1001234, 42, "abc123"], job["args"]
  end

  def test_delegates_command_to_command_handler
    payload = {
      "message" => {
        "message_id" => 10,
        "chat" => { "id" => 123_456 },
        "from" => { "id" => 123_456 },
        "text" => "/ping",
        "entities" => [{ "type" => "bot_command", "offset" => 0, "length" => 5 }]
      }
    }

    stub_request(:post, "#{TELEGRAM_API}/sendMessage")
      .to_return(status: 200, body: Oj.dump({ "ok" => true, "result" => {} }))

    Bot::WebhookHandler.new(payload).call

    assert_equal 0, Jobs::TranscribeJob.jobs.size
    assert_requested(:post, "#{TELEGRAM_API}/sendMessage")
  end

  def test_ignores_payload_without_message
    payload = { "update_id" => 1 }
    Bot::WebhookHandler.new(payload).call
    assert_equal 0, Jobs::TranscribeJob.jobs.size
  end

  def test_ignores_text_message_without_command
    payload = {
      "message" => {
        "message_id" => 10,
        "chat" => { "id" => -1001234 },
        "from" => { "id" => 999 },
        "text" => "hello world"
      }
    }

    Bot::WebhookHandler.new(payload).call
    assert_equal 0, Jobs::TranscribeJob.jobs.size
  end

  def test_handles_command_with_bot_mention
    payload = {
      "message" => {
        "message_id" => 10,
        "chat" => { "id" => 123_456 },
        "from" => { "id" => 123_456 },
        "text" => "/ping@mybot",
        "entities" => [{ "type" => "bot_command", "offset" => 0, "length" => 11 }]
      }
    }

    stub_request(:post, "#{TELEGRAM_API}/sendMessage")
      .to_return(status: 200, body: Oj.dump({ "ok" => true, "result" => {} }))

    Bot::WebhookHandler.new(payload).call
    assert_requested(:post, "#{TELEGRAM_API}/sendMessage")
  end
end
