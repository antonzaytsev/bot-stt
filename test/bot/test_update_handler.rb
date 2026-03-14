# frozen_string_literal: true

require_relative "../test_helper"

class TestUpdateHandler < Minitest::Test
  ADMIN_ID = 123_456
  GROUP_ID = -1001234

  def setup
    Sidekiq::Worker.clear_all
    ENV.delete("ALLOWED_CHAT_ID")
  end

  def test_enqueues_transcribe_job_for_admin_voice
    payload = voice_payload(chat_id: ADMIN_ID, chat_type: "private", from_id: ADMIN_ID)

    Bot::UpdateHandler.new(payload).call

    assert_equal 1, Jobs::TranscribeJob.jobs.size
    assert_equal [ADMIN_ID, 42, "abc123"], Jobs::TranscribeJob.jobs.first["args"]
  end

  def test_enqueues_transcribe_job_for_allowed_group
    ENV["ALLOWED_CHAT_ID"] = GROUP_ID.to_s
    payload = voice_payload(chat_id: GROUP_ID, chat_type: "supergroup", from_id: 999)

    Bot::UpdateHandler.new(payload).call

    assert_equal 1, Jobs::TranscribeJob.jobs.size
    assert_equal [GROUP_ID, 42, "abc123"], Jobs::TranscribeJob.jobs.first["args"]
  end

  def test_ignores_voice_from_non_allowed_group
    payload = voice_payload(chat_id: GROUP_ID, chat_type: "supergroup", from_id: ADMIN_ID)

    Bot::UpdateHandler.new(payload).call

    assert_equal 0, Jobs::TranscribeJob.jobs.size
  end

  def test_ignores_voice_from_non_admin_private_chat
    payload = voice_payload(chat_id: 999_999, chat_type: "private", from_id: 999_999)

    Bot::UpdateHandler.new(payload).call

    assert_equal 0, Jobs::TranscribeJob.jobs.size
  end

  def test_transcribe_request_via_reply_and_mention
    ENV["ALLOWED_CHAT_ID"] = GROUP_ID.to_s
    payload = transcribe_request_payload(
      chat_id: GROUP_ID, chat_type: "supergroup", from_id: 999,
      replied_message_id: 10, replied_file_id: "old_voice_123"
    )

    Bot::UpdateHandler.new(payload).call

    assert_equal 1, Jobs::TranscribeJob.jobs.size
    job = Jobs::TranscribeJob.jobs.first
    assert_equal [GROUP_ID, 10, "old_voice_123"], job["args"]
  end

  def test_transcribe_request_ignored_in_non_allowed_group
    payload = transcribe_request_payload(
      chat_id: GROUP_ID, chat_type: "supergroup", from_id: 999,
      replied_message_id: 10, replied_file_id: "old_voice_123"
    )

    Bot::UpdateHandler.new(payload).call

    assert_equal 0, Jobs::TranscribeJob.jobs.size
  end

  def test_transcribe_request_ignored_when_reply_is_not_voice
    ENV["ALLOWED_CHAT_ID"] = GROUP_ID.to_s
    payload = {
      "update_id" => 1,
      "message" => {
        "message_id" => 50,
        "chat" => { "id" => GROUP_ID, "type" => "supergroup" },
        "from" => { "id" => 999 },
        "text" => "@curse_assistant_bot",
        "entities" => [{ "type" => "mention", "offset" => 0, "length" => 20 }],
        "reply_to_message" => {
          "message_id" => 10,
          "text" => "just a text message"
        }
      }
    }

    Bot::UpdateHandler.new(payload).call

    assert_equal 0, Jobs::TranscribeJob.jobs.size
  end

  def test_delegates_command_in_private_admin_chat
    payload = command_payload(chat_id: ADMIN_ID, chat_type: "private", from_id: ADMIN_ID)

    stub_request(:post, "#{TELEGRAM_API}/sendMessage")
      .to_return(status: 200, body: Oj.dump({ "ok" => true, "result" => {} }))

    Bot::UpdateHandler.new(payload).call

    assert_equal 0, Jobs::TranscribeJob.jobs.size
    assert_requested(:post, "#{TELEGRAM_API}/sendMessage")
  end

  def test_ignores_command_in_group_chat
    ENV["ALLOWED_CHAT_ID"] = GROUP_ID.to_s
    payload = command_payload(chat_id: GROUP_ID, chat_type: "supergroup", from_id: ADMIN_ID)

    Bot::UpdateHandler.new(payload).call

    assert_equal 0, Jobs::TranscribeJob.jobs.size
  end

  def test_ignores_payload_without_message
    Bot::UpdateHandler.new({ "update_id" => 1 }).call
    assert_equal 0, Jobs::TranscribeJob.jobs.size
  end

  def test_ignores_text_message_without_command
    payload = {
      "update_id" => 1,
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
      "update_id" => 1,
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

  private

  def voice_payload(chat_id:, chat_type:, from_id:)
    {
      "update_id" => 1,
      "message" => {
        "message_id" => 42,
        "chat" => { "id" => chat_id, "type" => chat_type },
        "from" => { "id" => from_id },
        "voice" => { "file_id" => "abc123", "duration" => 5 }
      }
    }
  end

  def transcribe_request_payload(chat_id:, chat_type:, from_id:, replied_message_id:, replied_file_id:)
    {
      "update_id" => 1,
      "message" => {
        "message_id" => 50,
        "chat" => { "id" => chat_id, "type" => chat_type },
        "from" => { "id" => from_id },
        "text" => "@curse_assistant_bot",
        "entities" => [{ "type" => "mention", "offset" => 0, "length" => 20 }],
        "reply_to_message" => {
          "message_id" => replied_message_id,
          "voice" => { "file_id" => replied_file_id, "duration" => 10 }
        }
      }
    }
  end

  def command_payload(chat_id:, chat_type:, from_id:)
    {
      "update_id" => 1,
      "message" => {
        "message_id" => 10,
        "chat" => { "id" => chat_id, "type" => chat_type },
        "from" => { "id" => from_id },
        "text" => "/ping",
        "entities" => [{ "type" => "bot_command", "offset" => 0, "length" => 5 }]
      }
    }
  end
end
