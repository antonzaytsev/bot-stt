# frozen_string_literal: true

require_relative "../test_helper"

class TestTranscribeJob < Minitest::Test
  def setup
    Sidekiq::Worker.clear_all
    Bot::Stats.instance_variable_set(:@processed, 0)
    Bot::Stats.instance_variable_set(:@failed, 0)
    Bot::Stats.instance_variable_set(:@last_reset_date, Date.today)

    Sidekiq.redis { |c| c.call("FLUSHDB") }

    stub_request(:post, "#{TELEGRAM_API}/getFile")
      .to_return(status: 200, body: Oj.dump({ "ok" => true, "result" => { "file_path" => "voice/file.ogg" } }))

    stub_request(:get, "https://api.telegram.org/file/bottest-bot-token/voice/file.ogg")
      .to_return(status: 200, body: "audio-bytes")

    stub_request(:post, "https://api.openai.com/v1/audio/transcriptions")
      .to_return(status: 200, body: Oj.dump({ "text" => "Transcribed text" }))

    stub_request(:post, "#{TELEGRAM_API}/sendMessage")
      .to_return(status: 200, body: Oj.dump({ "ok" => true, "result" => { "message_id" => 100 } }))

    stub_request(:post, "https://api.openai.com/v1/chat/completions")
      .to_return(status: 200, body: Oj.dump({
        "choices" => [{ "message" => { "content" => "Formatted text." } }]
      }))

    stub_request(:post, "#{TELEGRAM_API}/editMessageText")
      .to_return(status: 200, body: Oj.dump({ "ok" => true, "result" => {} }))
  end

  def test_happy_path_transcribes_and_replies
    Jobs::TranscribeJob.new.perform(-1001234, 42, "file_abc")

    assert_requested(:post, "#{TELEGRAM_API}/getFile")
    assert_requested(:get, "https://api.telegram.org/file/bottest-bot-token/voice/file.ogg")
    assert_requested(:post, "https://api.openai.com/v1/audio/transcriptions")
    assert_requested(:post, "#{TELEGRAM_API}/sendMessage") { |req|
      body = Oj.load(req.body)
      body["text"] == "Transcribed text" &&
        body["chat_id"] == -1001234 &&
        body["reply_to_message_id"] == 42
    }
    assert_requested(:post, "https://api.openai.com/v1/chat/completions")
    assert_requested(:post, "#{TELEGRAM_API}/editMessageText") { |req|
      body = Oj.load(req.body)
      body["text"] == "Formatted text." && body["message_id"] == 100
    }
    assert_equal 1, Bot::Stats.processed
    assert_equal 0, Bot::Stats.failed
  end

  def test_auto_format_skips_edit_when_text_unchanged
    stub_request(:post, "https://api.openai.com/v1/chat/completions")
      .to_return(status: 200, body: Oj.dump({
        "choices" => [{ "message" => { "content" => "Transcribed text" } }]
      }))

    Jobs::TranscribeJob.new.perform(-1001234, 42, "file_abc")

    assert_not_requested(:post, "#{TELEGRAM_API}/editMessageText")
  end

  def test_auto_format_failure_is_non_fatal
    stub_request(:post, "https://api.openai.com/v1/chat/completions")
      .to_return(status: 500, body: Oj.dump({ "error" => { "message" => "LLM error" } }))

    Jobs::TranscribeJob.new.perform(-1001234, 42, "file_abc")

    assert_not_requested(:post, "#{TELEGRAM_API}/editMessageText")
    assert_equal 1, Bot::Stats.processed
  end

  def test_marks_message_as_transcribed_in_redis
    Jobs::TranscribeJob.new.perform(-1001234, 42, "file_abc")

    exists = Sidekiq.redis { |c| c.call("EXISTS", "transcribed:-1001234:42") }
    assert_equal 1, exists
  end

  def test_skips_already_transcribed_message
    Sidekiq.redis { |c| c.call("SET", "transcribed:-1001234:42", "1") }

    Jobs::TranscribeJob.new.perform(-1001234, 42, "file_abc")

    assert_not_requested(:post, "#{TELEGRAM_API}/getFile")
    assert_not_requested(:post, "https://api.openai.com/v1/audio/transcriptions")
    assert_equal 0, Bot::Stats.processed
  end

  def test_records_failure_and_notifies_admin_on_whisper_error
    stub_request(:post, "https://api.openai.com/v1/audio/transcriptions")
      .to_return(status: 500, body: Oj.dump({ "error" => { "message" => "OpenAI server error" } }))

    assert_raises(RuntimeError) do
      Jobs::TranscribeJob.new.perform(-1001234, 42, "file_abc")
    end

    assert_equal 0, Bot::Stats.processed
    assert_equal 1, Bot::Stats.failed

    assert_requested(:post, "#{TELEGRAM_API}/sendMessage") { |req|
      body = Oj.load(req.body)
      body["chat_id"] == "123456" && body["text"].include?("OpenAI API")
    }
  end

  def test_records_failure_on_telegram_download_error
    stub_request(:get, "https://api.telegram.org/file/bottest-bot-token/voice/file.ogg")
      .to_return(status: 404, body: "Not Found")

    assert_raises(RuntimeError) do
      Jobs::TranscribeJob.new.perform(-1001234, 42, "file_abc")
    end

    assert_equal 1, Bot::Stats.failed
    assert_requested(:post, "#{TELEGRAM_API}/sendMessage") { |req|
      body = Oj.load(req.body)
      body["text"].include?("Telegram")
    }
  end

  def test_error_category_telegram
    job = Jobs::TranscribeJob.new
    cat = job.send(:error_category, RuntimeError.new("Telegram API error: not found"))
    assert_equal "Telegram API", cat
  end

  def test_error_category_openai
    job = Jobs::TranscribeJob.new
    cat = job.send(:error_category, RuntimeError.new("Whisper API error: bad audio"))
    assert_equal "OpenAI API", cat
  end

  def test_error_category_timeout
    job = Jobs::TranscribeJob.new
    cat = job.send(:error_category, RuntimeError.new("Errno::ETIMEDOUT"))
    assert_equal "Network timeout", cat
  end

  def test_error_category_unknown
    job = Jobs::TranscribeJob.new
    cat = job.send(:error_category, RuntimeError.new("Something else"))
    assert_equal "Unknown", cat
  end

  def test_admin_notification_failure_does_not_raise
    stub_request(:post, "https://api.openai.com/v1/audio/transcriptions")
      .to_return(status: 500, body: Oj.dump({ "error" => { "message" => "OpenAI error" } }))

    stub_request(:post, "#{TELEGRAM_API}/sendMessage")
      .to_return(status: 400, body: Oj.dump({ "ok" => false, "description" => "Server error" }))

    assert_raises(RuntimeError) do
      Jobs::TranscribeJob.new.perform(-1001234, 42, "file_abc")
    end
    assert_equal 1, Bot::Stats.failed
  end
end
