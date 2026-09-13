# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/jobs/transcribe_audio_job"

class TestTranscribeAudioJob < Minitest::Test
  CHAT_ID = -1001234
  MSG_ID = 42
  STATUS_MSG_ID = 300

  def setup
    Sidekiq::Worker.clear_all
    Bot::Stats.instance_variable_set(:@processed, 0)
    Bot::Stats.instance_variable_set(:@failed, 0)
    Bot::Stats.instance_variable_set(:@last_reset_date, Date.today)

    Sidekiq.redis { |c| c.call("FLUSHDB") }

    stub_request(:post, "#{TELEGRAM_API}/sendMessage")
      .to_return(status: 200, body: Oj.dump({ "ok" => true, "result" => { "message_id" => STATUS_MSG_ID } }))

    stub_request(:post, "#{TELEGRAM_API}/editMessageText")
      .to_return(status: 200, body: Oj.dump({ "ok" => true, "result" => {} }))

    stub_request(:post, "#{TELEGRAM_API}/sendDocument")
      .to_return(status: 200, body: Oj.dump({ "ok" => true, "result" => { "message_id" => 301 } }))

    stub_request(:post, "#{TELEGRAM_API}/getFile")
      .to_return(status: 200, body: Oj.dump({ "ok" => true, "result" => { "file_path" => "music/file.mp3" } }))

    stub_request(:get, "https://api.telegram.org/file/bottest-bot-token/music/file.mp3")
      .to_return(status: 200, body: "audio-bytes")

    stub_request(:post, "https://api.openai.com/v1/audio/transcriptions")
      .to_return(status: 200, body: Oj.dump({ "text" => "Raw transcription" }))

    stub_request(:post, "https://api.openai.com/v1/chat/completions")
      .to_return(status: 200, body: Oj.dump({
        "choices" => [{ "message" => { "content" => "Formatted text." } }]
      }))

    @tmp_dir = Dir.mktmpdir("audio_test")
  end

  def teardown
    super # Minitest::Test#teardown is WebMock's stub reset
    FileUtils.remove_entry(@tmp_dir) if @tmp_dir && File.directory?(@tmp_dir)
  end

  def test_happy_path_replies_with_text_in_status_message
    perform_with_chunks(chunk_count: 1)

    assert_requested(:post, "#{TELEGRAM_API}/getFile")
    assert_requested(:get, "https://api.telegram.org/file/bottest-bot-token/music/file.mp3")
    assert_requested(:post, "https://api.openai.com/v1/audio/transcriptions")
    assert_requested(:post, "#{TELEGRAM_API}/editMessageText") { |req|
      body = Oj.load(req.body)
      body["message_id"] == STATUS_MSG_ID && body["text"] == "Formatted text."
    }
    assert_not_requested(:post, "#{TELEGRAM_API}/sendDocument")
    assert_equal 1, Bot::Stats.processed
    assert_equal 0, Bot::Stats.failed
  end

  def test_status_message_is_sent_as_reply_to_the_upload
    perform_with_chunks(chunk_count: 1)

    assert_requested(:post, "#{TELEGRAM_API}/sendMessage") { |req|
      body = Oj.load(req.body)
      body["chat_id"] == CHAT_ID && body["reply_to_message_id"] == MSG_ID && body["text"].include?("Transcribing")
    }
  end

  def test_transcribes_every_chunk_and_joins_the_parts
    perform_with_chunks(chunk_count: 3)

    assert_requested(:post, "https://api.openai.com/v1/audio/transcriptions", times: 3)
    assert_requested(:post, "#{TELEGRAM_API}/editMessageText") { |req|
      Oj.load(req.body)["text"] == "Formatted text.\n\nFormatted text.\n\nFormatted text."
    }
  end

  def test_sends_a_text_file_when_transcript_is_too_long
    long_text = "word " * 1000
    stub_request(:post, "https://api.openai.com/v1/chat/completions")
      .to_return(status: 200, body: Oj.dump({ "choices" => [{ "message" => { "content" => long_text } }] }))

    perform_with_chunks(chunk_count: 1, file_name: "podcast episode.mp3")

    assert_requested(:post, "#{TELEGRAM_API}/sendDocument") { |req|
      req.body.include?("filename=\"podcast episode.txt\"") &&
        req.body.include?("word word") &&
        req.body.include?(MSG_ID.to_s)
    }
    assert_equal 1, Bot::Stats.processed
  end

  def test_falls_back_to_default_document_name_without_a_file_name
    long_text = "word " * 1000
    stub_request(:post, "https://api.openai.com/v1/chat/completions")
      .to_return(status: 200, body: Oj.dump({ "choices" => [{ "message" => { "content" => long_text } }] }))

    perform_with_chunks(chunk_count: 1, file_name: nil)

    assert_requested(:post, "#{TELEGRAM_API}/sendDocument") { |req|
      req.body.include?("filename=\"transcript.txt\"")
    }
  end

  def test_rejects_files_over_the_telegram_download_limit
    Jobs::TranscribeAudioJob.new.perform(CHAT_ID, MSG_ID, "file_abc", 60, "big.mp3", 25 * 1024 * 1024)

    assert_not_requested(:post, "#{TELEGRAM_API}/getFile")
    assert_requested(:post, "#{TELEGRAM_API}/sendMessage") { |req|
      Oj.load(req.body)["text"].include?("too large")
    }
    assert_equal 1, Sidekiq.redis { |c| c.call("EXISTS", "transcribed:#{CHAT_ID}:#{MSG_ID}") }
  end

  def test_skips_already_transcribed_message
    Sidekiq.redis { |c| c.call("SET", "transcribed:#{CHAT_ID}:#{MSG_ID}", "1") }

    perform_with_chunks(chunk_count: 1)

    assert_not_requested(:post, "#{TELEGRAM_API}/getFile")
    assert_equal 0, Bot::Stats.processed
  end

  def test_uses_raw_transcription_when_formatting_fails
    stub_request(:post, "https://api.openai.com/v1/chat/completions")
      .to_return(status: 500, body: Oj.dump({ "error" => { "message" => "LLM error" } }))

    perform_with_chunks(chunk_count: 1)

    assert_requested(:post, "#{TELEGRAM_API}/editMessageText") { |req|
      Oj.load(req.body)["text"] == "Raw transcription"
    }
    assert_equal 1, Bot::Stats.processed
  end

  def test_records_failure_and_notifies_admin_on_whisper_error
    stub_request(:post, "https://api.openai.com/v1/audio/transcriptions")
      .to_return(status: 500, body: Oj.dump({ "error" => { "message" => "OpenAI server error" } }))

    assert_raises(RuntimeError) { perform_with_chunks(chunk_count: 1) }

    assert_equal 0, Bot::Stats.processed
    assert_equal 1, Bot::Stats.failed
    assert_requested(:post, "#{TELEGRAM_API}/editMessageText") { |req|
      Oj.load(req.body)["text"].include?("Failed")
    }
    assert_requested(:post, "#{TELEGRAM_API}/sendMessage") { |req|
      body = Oj.load(req.body)
      body["chat_id"] == "123456" && body["text"].include?("OpenAI API")
    }
  end

  def test_conversion_failure_is_reported_as_audio_conversion
    failing_downloader = Object.new
    def failing_downloader.split_audio(path, chunk_seconds:, output_dir:)
      raise "Command failed (exit 1): ffmpeg"
    end

    Jobs::TranscribeAudioJob.stub(:make_downloader, failing_downloader) do
      assert_raises(RuntimeError) do
        Jobs::TranscribeAudioJob.new.perform(CHAT_ID, MSG_ID, "file_abc", 60, "track.mp3", 1024)
      end
    end

    assert_equal 1, Bot::Stats.failed
    assert_requested(:post, "#{TELEGRAM_API}/sendMessage") { |req|
      Oj.load(req.body)["text"].include?("Audio conversion")
    }
  end

  private

  def perform_with_chunks(chunk_count:, file_name: "track.mp3", duration: 60)
    chunks = Array.new(chunk_count) do |i|
      path = File.join(@tmp_dir, format("chunk_%03d.ogg", i))
      File.write(path, "fake-chunk-bytes")
      path
    end

    downloader = Object.new
    downloader.define_singleton_method(:split_audio) { |_path, chunk_seconds:, output_dir:| chunks }

    Jobs::TranscribeAudioJob.stub(:make_downloader, downloader) do
      Jobs::TranscribeAudioJob.new.perform(CHAT_ID, MSG_ID, "file_abc", duration, file_name, 1024)
    end
  end
end
