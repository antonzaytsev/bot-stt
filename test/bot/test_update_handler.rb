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
    assert_equal [ADMIN_ID, 42, "abc123", 5], Jobs::TranscribeJob.jobs.first["args"]
  end

  def test_enqueues_transcribe_job_for_allowed_group
    ENV["ALLOWED_CHAT_ID"] = GROUP_ID.to_s
    payload = voice_payload(chat_id: GROUP_ID, chat_type: "supergroup", from_id: 999)

    Bot::UpdateHandler.new(payload).call

    assert_equal 1, Jobs::TranscribeJob.jobs.size
    assert_equal [GROUP_ID, 42, "abc123", 5], Jobs::TranscribeJob.jobs.first["args"]
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

  def test_enqueues_audio_job_for_audio_message
    payload = audio_payload(chat_id: ADMIN_ID, chat_type: "private", from_id: ADMIN_ID)

    Bot::UpdateHandler.new(payload).call

    assert_equal 1, Jobs::TranscribeAudioJob.jobs.size
    assert_equal [ADMIN_ID, 42, "audio123", 180, "track.mp3", 2048], Jobs::TranscribeAudioJob.jobs.first["args"]
  end

  def test_enqueues_audio_job_for_audio_document
    payload = document_payload(
      chat_id: ADMIN_ID, chat_type: "private", from_id: ADMIN_ID,
      mime_type: "audio/mpeg", file_name: "meeting.mp3"
    )

    Bot::UpdateHandler.new(payload).call

    assert_equal 1, Jobs::TranscribeAudioJob.jobs.size
    assert_equal [ADMIN_ID, 42, "doc123", nil, "meeting.mp3", 4096], Jobs::TranscribeAudioJob.jobs.first["args"]
  end

  def test_enqueues_audio_job_for_document_with_audio_extension_only
    payload = document_payload(
      chat_id: ADMIN_ID, chat_type: "private", from_id: ADMIN_ID,
      mime_type: "application/octet-stream", file_name: "voice-memo.M4A"
    )

    Bot::UpdateHandler.new(payload).call

    assert_equal 1, Jobs::TranscribeAudioJob.jobs.size
  end

  def test_ignores_non_audio_document
    payload = document_payload(
      chat_id: ADMIN_ID, chat_type: "private", from_id: ADMIN_ID,
      mime_type: "application/pdf", file_name: "invoice.pdf"
    )

    Bot::UpdateHandler.new(payload).call

    assert_equal 0, Jobs::TranscribeAudioJob.jobs.size
  end

  def test_enqueues_audio_job_in_allowed_group
    ENV["ALLOWED_CHAT_ID"] = GROUP_ID.to_s
    payload = audio_payload(chat_id: GROUP_ID, chat_type: "supergroup", from_id: 999)

    Bot::UpdateHandler.new(payload).call

    assert_equal 1, Jobs::TranscribeAudioJob.jobs.size
  end

  def test_ignores_audio_from_non_allowed_group
    payload = audio_payload(chat_id: GROUP_ID, chat_type: "supergroup", from_id: 999)

    Bot::UpdateHandler.new(payload).call

    assert_equal 0, Jobs::TranscribeAudioJob.jobs.size
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
    assert_equal [GROUP_ID, 10, "old_voice_123", 10], job["args"]
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

  def test_enqueues_media_job_for_every_youtube_link_shape
    urls = [
      "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
      "https://youtube.com/watch?v=dQw4w9WgXcQ&t=30s",
      "https://m.youtube.com/watch?v=dQw4w9WgXcQ",
      "https://music.youtube.com/watch?v=dQw4w9WgXcQ",
      "https://youtu.be/dQw4w9WgXcQ",
      "https://www.youtube.com/shorts/dQw4w9WgXcQ",
      "https://www.youtube.com/live/dQw4w9WgXcQ"
    ]

    urls.each do |url|
      Sidekiq::Worker.clear_all
      Bot::UpdateHandler.new(text_payload(url)).call

      assert_equal 1, Jobs::TranscribeMediaJob.jobs.size, "expected a job for #{url}"
      assert_equal [ADMIN_ID, 42, url, false], Jobs::TranscribeMediaJob.jobs.first["args"]
    end
  end

  def test_picks_the_link_out_of_surrounding_prose
    Bot::UpdateHandler.new(text_payload("look at this https://youtu.be/dQw4w9WgXcQ it is good")).call

    assert_equal 1, Jobs::TranscribeMediaJob.jobs.size
    assert_equal "https://youtu.be/dQw4w9WgXcQ", Jobs::TranscribeMediaJob.jobs.first["args"][2]
  end

  def test_finds_a_link_hidden_behind_a_text_link_entity
    payload = text_payload("watch this")
    payload["message"]["entities"] = [
      { "type" => "text_link", "offset" => 0, "length" => 10, "url" => "https://youtu.be/dQw4w9WgXcQ" }
    ]

    Bot::UpdateHandler.new(payload).call

    assert_equal 1, Jobs::TranscribeMediaJob.jobs.size
  end

  def test_ignores_non_youtube_links
    Bot::UpdateHandler.new(text_payload("https://vimeo.com/12345")).call

    assert_equal 0, Jobs::TranscribeMediaJob.jobs.size
  end

  def test_summarize_command_with_a_youtube_url_is_still_a_command
    payload = text_payload("/summarize https://youtu.be/dQw4w9WgXcQ")
    payload["message"]["entities"] = [{ "type" => "bot_command", "offset" => 0, "length" => 10 }]

    Bot::UpdateHandler.new(payload).call

    # CommandHandler enqueues it with auto_summarize on, rather than the bare-link path.
    assert_equal 1, Jobs::TranscribeMediaJob.jobs.size
    assert_equal true, Jobs::TranscribeMediaJob.jobs.first["args"][3]
  end

  def test_ignores_a_youtube_link_in_a_non_allowed_group
    payload = text_payload("https://youtu.be/dQw4w9WgXcQ", chat_id: GROUP_ID, chat_type: "supergroup", from_id: 999)

    Bot::UpdateHandler.new(payload).call

    assert_equal 0, Jobs::TranscribeMediaJob.jobs.size
  end

  def test_enqueues_media_job_in_an_allowed_group
    ENV["ALLOWED_CHAT_ID"] = GROUP_ID.to_s
    payload = text_payload("https://youtu.be/dQw4w9WgXcQ", chat_id: GROUP_ID, chat_type: "supergroup", from_id: 999)

    Bot::UpdateHandler.new(payload).call

    assert_equal 1, Jobs::TranscribeMediaJob.jobs.size
  end

  def test_routes_callback_queries_to_the_callback_handler
    stub_request(:post, "#{TELEGRAM_API}/answerCallbackQuery")
      .to_return(status: 200, body: Oj.dump({ "ok" => true, "result" => true }))
    Sidekiq.redis { |c| c.call("FLUSHDB") }
    Bot::TranscriptStore.save(token: "tok", chat_id: ADMIN_ID, text: "Transcript.", source: "voice")

    payload = {
      "update_id" => 1,
      "callback_query" => {
        "id" => "cb-1", "data" => "s|tok", "from" => { "id" => ADMIN_ID },
        "message" => { "message_id" => 300, "chat" => { "id" => ADMIN_ID, "type" => "private" } }
      }
    }

    Bot::UpdateHandler.new(payload).call

    assert_equal 1, Jobs::SummarizeJob.jobs.size
  end

  private

  def text_payload(text, chat_id: ADMIN_ID, chat_type: "private", from_id: ADMIN_ID)
    {
      "update_id" => 1,
      "message" => {
        "message_id" => 42,
        "chat" => { "id" => chat_id, "type" => chat_type },
        "from" => { "id" => from_id },
        "text" => text
      }
    }
  end

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

  def audio_payload(chat_id:, chat_type:, from_id:)
    {
      "update_id" => 1,
      "message" => {
        "message_id" => 42,
        "chat" => { "id" => chat_id, "type" => chat_type },
        "from" => { "id" => from_id },
        "audio" => {
          "file_id" => "audio123", "duration" => 180,
          "file_name" => "track.mp3", "file_size" => 2048
        }
      }
    }
  end

  def document_payload(chat_id:, chat_type:, from_id:, mime_type:, file_name:)
    {
      "update_id" => 1,
      "message" => {
        "message_id" => 42,
        "chat" => { "id" => chat_id, "type" => chat_type },
        "from" => { "id" => from_id },
        "document" => {
          "file_id" => "doc123", "mime_type" => mime_type,
          "file_name" => file_name, "file_size" => 4096
        }
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
