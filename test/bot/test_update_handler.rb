# frozen_string_literal: true

require_relative "../test_helper"

class TestUpdateHandler < Minitest::Test
  ADMIN_ID = 123_456

  def setup
    Sidekiq::Worker.clear_all
  end

  def test_enqueues_transcribe_job_for_voice_message
    payload = {
      "update_id" => 1,
      "message" => {
        "message_id" => 42,
        "chat" => { "id" => ADMIN_ID, "type" => "private" },
        "from" => { "id" => ADMIN_ID },
        "voice" => { "file_id" => "abc123", "duration" => 5 }
      }
    }

    Bot::UpdateHandler.new(payload).call

    assert_equal 1, Jobs::TranscribeJob.jobs.size
    job = Jobs::TranscribeJob.jobs.first
    assert_equal [ADMIN_ID, 42, "abc123"], job["args"]
  end

  def test_delegates_command_to_command_handler
    payload = {
      "update_id" => 2,
      "message" => {
        "message_id" => 10,
        "chat" => { "id" => ADMIN_ID, "type" => "private" },
        "from" => { "id" => ADMIN_ID },
        "text" => "/ping",
        "entities" => [{ "type" => "bot_command", "offset" => 0, "length" => 5 }]
      }
    }

    stub_request(:post, "#{TELEGRAM_API}/sendMessage")
      .to_return(status: 200, body: Oj.dump({ "ok" => true, "result" => {} }))

    Bot::UpdateHandler.new(payload).call

    assert_equal 0, Jobs::TranscribeJob.jobs.size
    assert_requested(:post, "#{TELEGRAM_API}/sendMessage")
  end

  def test_ignores_payload_without_message
    payload = { "update_id" => 1 }
    Bot::UpdateHandler.new(payload).call
    assert_equal 0, Jobs::TranscribeJob.jobs.size
  end

  def test_ignores_group_chat_voice
    payload = {
      "update_id" => 3,
      "message" => {
        "message_id" => 42,
        "chat" => { "id" => -1001234, "type" => "supergroup" },
        "from" => { "id" => ADMIN_ID },
        "voice" => { "file_id" => "abc123", "duration" => 5 }
      }
    }

    Bot::UpdateHandler.new(payload).call
    assert_equal 0, Jobs::TranscribeJob.jobs.size
  end

  def test_ignores_non_admin_private_chat
    payload = {
      "update_id" => 4,
      "message" => {
        "message_id" => 42,
        "chat" => { "id" => 999_999, "type" => "private" },
        "from" => { "id" => 999_999 },
        "voice" => { "file_id" => "abc123", "duration" => 5 }
      }
    }

    Bot::UpdateHandler.new(payload).call
    assert_equal 0, Jobs::TranscribeJob.jobs.size
  end

  def test_ignores_text_message_without_command
    payload = {
      "update_id" => 5,
      "message" => {
        "message_id" => 10,
        "chat" => { "id" => ADMIN_ID, "type" => "private" },
        "from" => { "id" => ADMIN_ID },
        "text" => "hello world"
      }
    }

    Bot::UpdateHandler.new(payload).call
    assert_equal 0, Jobs::TranscribeJob.jobs.size
  end

  def test_handles_command_with_bot_mention
    payload = {
      "update_id" => 6,
      "message" => {
        "message_id" => 10,
        "chat" => { "id" => ADMIN_ID, "type" => "private" },
        "from" => { "id" => ADMIN_ID },
        "text" => "/ping@mybot",
        "entities" => [{ "type" => "bot_command", "offset" => 0, "length" => 11 }]
      }
    }

    stub_request(:post, "#{TELEGRAM_API}/sendMessage")
      .to_return(status: 200, body: Oj.dump({ "ok" => true, "result" => {} }))

    Bot::UpdateHandler.new(payload).call
    assert_requested(:post, "#{TELEGRAM_API}/sendMessage")
  end
end
