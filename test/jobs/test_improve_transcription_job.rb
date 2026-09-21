# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/jobs/improve_transcription_job"

class TestImproveTranscriptionJob < Minitest::Test
  CHAT_ID = -1001234
  BOT_MSG_ID = 100

  def setup
    Sidekiq::Worker.clear_all
    Sidekiq.redis { |c| c.call("FLUSHDB") }

    stub_request(:post, "#{TELEGRAM_API}/getFile")
      .to_return(status: 200, body: Oj.dump({ "ok" => true, "result" => { "file_path" => "voice/file.ogg" } }))
    stub_request(:get, "https://api.telegram.org/file/bottest-bot-token/voice/file.ogg")
      .to_return(status: 200, body: "audio-bytes")
    stub_request(:post, "https://api.openai.com/v1/audio/transcriptions")
      .to_return(status: 200, body: Oj.dump({ "text" => "Second pass" }))
    stub_request(:post, "https://api.openai.com/v1/chat/completions")
      .to_return(status: 200, body: Oj.dump({ "choices" => [{ "message" => { "content" => "Improved text." } }] }))
    stub_request(:post, "#{TELEGRAM_API}/editMessageText")
      .to_return(status: 200, body: Oj.dump({ "ok" => true, "result" => {} }))
    stub_request(:post, "#{TELEGRAM_API}/sendDocument")
      .to_return(status: 200, body: Oj.dump({ "ok" => true, "result" => { "message_id" => 101 } }))
  end

  # Editing the message must not drop the Summarize button that was on it.
  def test_edit_keeps_the_summary_button
    Bot::TranscriptStore.save(token: "tok1", chat_id: CHAT_ID, text: "Original.", source: "voice", button: true)
    store_meta("as_file" => false, "token" => "tok1")

    Jobs::ImproveTranscriptionJob.new.perform(CHAT_ID, BOT_MSG_ID)

    assert_requested(:post, "#{TELEGRAM_API}/editMessageText") { |req|
      body = Oj.load(req.body)
      body["text"] == "Improved text." &&
        body["reply_markup"]["inline_keyboard"][0][0]["callback_data"] == "s|tok1"
    }
  end

  def test_improved_text_replaces_what_summarize_would_read
    Bot::TranscriptStore.save(token: "tok1", chat_id: CHAT_ID, text: "Original.", source: "voice", button: true)
    store_meta("as_file" => false, "token" => "tok1")

    Jobs::ImproveTranscriptionJob.new.perform(CHAT_ID, BOT_MSG_ID)

    assert_equal "Improved text.", Bot::TranscriptStore.fetch("tok1")["text"]
  end

  # A .txt document has no text to edit, so the improvement comes back as a file.
  def test_file_delivery_sends_a_new_document
    store_meta("as_file" => true, "token" => "tok1")

    Jobs::ImproveTranscriptionJob.new.perform(CHAT_ID, BOT_MSG_ID)

    assert_not_requested(:post, "#{TELEGRAM_API}/editMessageText")
    assert_requested(:post, "#{TELEGRAM_API}/sendDocument") { |req|
      req.body.include?("transcript-improved.txt") && req.body.include?("Improved text.")
    }
  end

  def test_metadata_without_a_token_edits_without_a_keyboard
    store_meta("as_file" => false, "token" => nil)

    Jobs::ImproveTranscriptionJob.new.perform(CHAT_ID, BOT_MSG_ID)

    assert_requested(:post, "#{TELEGRAM_API}/editMessageText") { |req|
      Oj.load(req.body)["reply_markup"].nil?
    }
  end

  def test_cooldown_blocks_a_second_run
    store_meta("as_file" => false, "token" => nil)

    Jobs::ImproveTranscriptionJob.new.perform(CHAT_ID, BOT_MSG_ID)
    WebMock.reset_executed_requests!
    Jobs::ImproveTranscriptionJob.new.perform(CHAT_ID, BOT_MSG_ID)

    assert_not_requested(:post, "https://api.openai.com/v1/audio/transcriptions")
  end

  private

  def store_meta(extra)
    meta = { "file_id" => "file_abc", "text" => "Original." }.merge(extra)
    Sidekiq.redis { |c| c.call("SET", "transcription_meta:#{CHAT_ID}:#{BOT_MSG_ID}", Oj.dump(meta)) }
  end
end
