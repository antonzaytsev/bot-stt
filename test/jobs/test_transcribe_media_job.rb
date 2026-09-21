# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/jobs/transcribe_media_job"

class TestTranscribeMediaJob < Minitest::Test
  CHAT_ID = -1001234
  MSG_ID = 42
  STATUS_MSG_ID = 300
  URL = "https://youtu.be/abc123"

  # Stands in for yt-dlp and ffmpeg, and records whether either was asked to do
  # anything — a cache hit must reach neither.
  class FakeDownloader
    attr_reader :downloads

    def initialize(info:, chunks:)
      @info = info
      @chunks = chunks
      @downloads = 0
    end

    def probe(_url) = @info

    def download(_url, output_dir:)
      @downloads += 1
      File.join(output_dir, "audio.opus")
    end

    def split_audio(_path, chunk_seconds:, output_dir:) = @chunks
  end

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
    stub_request(:post, "https://api.openai.com/v1/audio/transcriptions")
      .to_return(status: 200, body: Oj.dump({ "text" => "Raw transcription" }))
    stub_request(:post, "https://api.openai.com/v1/chat/completions")
      .to_return(status: 200, body: Oj.dump({ "choices" => [{ "message" => { "content" => "Formatted text." } }] }))

    @tmp_dir = Dir.mktmpdir("media_test")
  end

  def teardown
    super
    FileUtils.remove_entry(@tmp_dir) if @tmp_dir && File.directory?(@tmp_dir)
    ENV.delete("MEDIA_CONFIRM_MINUTES")
  end

  def test_transcribes_and_sends_the_transcript_as_a_file
    perform

    assert_requested(:post, "https://api.openai.com/v1/audio/transcriptions")
    assert_requested(:post, "#{TELEGRAM_API}/sendDocument") { |req|
      req.body.include?("filename=\"A talk.txt\"") && req.body.include?("Formatted text.")
    }
    assert_equal 1, Bot::Stats.processed
  end

  def test_caption_carries_title_duration_and_size
    perform

    assert_requested(:post, "#{TELEGRAM_API}/sendDocument") { |req|
      utf8(req.body).include?("A talk · 10m · 15 characters")
    }
  end

  def test_transcript_is_cached_under_the_media_identity
    perform

    record = Bot::MediaCache.fetch_transcript("youtube:abc123")
    assert_equal "Formatted text.", record["text"]
    assert_equal "A talk", record["title"]
  end

  def test_cache_hit_skips_download_and_whisper
    Bot::MediaCache.save_transcript("youtube:abc123", text: "Cached transcript.", title: "A talk", duration: 600)
    downloader = perform

    assert_equal 0, downloader.downloads
    assert_not_requested(:post, "https://api.openai.com/v1/audio/transcriptions")
    assert_requested(:post, "#{TELEGRAM_API}/sendDocument") { |req|
      req.body.include?("Cached transcript.") && req.body.include?("already transcribed")
    }
  end

  def test_long_media_asks_for_confirmation_instead_of_downloading
    downloader = perform(duration: 7200)

    assert_equal 0, downloader.downloads
    assert_not_requested(:post, "https://api.openai.com/v1/audio/transcriptions")
    assert_requested(:post, "#{TELEGRAM_API}/editMessageText") { |req|
      body = Oj.load(req.body)
      body["text"].include?("2h 0m") && body["text"].include?("$0.72") &&
        body["reply_markup"]["inline_keyboard"][0][0]["callback_data"].start_with?("m|")
    }
  end

  def test_confirmed_long_media_is_processed
    downloader = perform(duration: 7200, confirmed: true)

    assert_equal 1, downloader.downloads
    assert_requested(:post, "#{TELEGRAM_API}/sendDocument")
  end

  def test_threshold_is_configurable
    ENV["MEDIA_CONFIRM_MINUTES"] = "5"
    downloader = perform(duration: 600)

    assert_equal 0, downloader.downloads
  end

  def test_blank_threshold_falls_back_to_the_default
    ENV["MEDIA_CONFIRM_MINUTES"] = ""
    downloader = perform(duration: 45)

    assert_equal 1800, Jobs::TranscribeMediaJob.confirm_seconds
    assert_equal 1, downloader.downloads
    assert_requested(:post, "#{TELEGRAM_API}/sendDocument")
  end

  def test_garbage_threshold_falls_back_to_the_default
    ENV["MEDIA_CONFIRM_MINUTES"] = "thirty"

    assert_equal 1800, Jobs::TranscribeMediaJob.confirm_seconds
  end

  def test_live_stream_is_refused_before_anything_is_fetched
    downloader = perform(info_overrides: { "live_status" => "is_live" })

    assert_equal 0, downloader.downloads
    assert_requested(:post, "#{TELEGRAM_API}/editMessageText") { |req|
      Oj.load(req.body)["text"].include?("Live streams")
    }
  end

  def test_playlist_is_refused
    downloader = perform(info_overrides: { "_type" => "playlist" })

    assert_equal 0, downloader.downloads
    assert_requested(:post, "#{TELEGRAM_API}/editMessageText") { |req|
      Oj.load(req.body)["text"].include?("Playlists")
    }
  end

  def test_summarize_button_is_attached_when_not_auto_summarizing
    perform

    assert_requested(:post, "#{TELEGRAM_API}/sendDocument") { |req|
      req.body.include?("Summarize") && req.body.include?("callback_data")
    }
    assert_equal 0, Jobs::SummarizeJob.jobs.size
  end

  def test_auto_summarize_enqueues_the_summary_without_a_button
    perform(auto_summarize: true)

    assert_equal 1, Jobs::SummarizeJob.jobs.size
    token = Jobs::SummarizeJob.jobs.first["args"][0]
    assert_equal "Formatted text.", Bot::TranscriptStore.fetch(token)["text"]
    assert_requested(:post, "#{TELEGRAM_API}/sendDocument") { |req|
      !req.body.include?("Summarize")
    }
  end

  def test_without_a_source_message_the_status_is_a_plain_message
    perform(message_id: nil)

    assert_requested(:post, "#{TELEGRAM_API}/sendMessage") { |req|
      Oj.load(req.body)["reply_to_message_id"].nil?
    }
  end

  def test_download_failure_is_reported_in_plain_language
    failing = FakeDownloader.new(info: info, chunks: [])
    def failing.download(_url, output_dir:)
      raise "Command failed (exit 1): yt-dlp\nERROR: Video unavailable"
    end

    Jobs::TranscribeMediaJob.stub(:make_downloader, failing) do
      assert_raises(RuntimeError) { Jobs::TranscribeMediaJob.new.perform(CHAT_ID, MSG_ID, URL) }
    end

    assert_equal 1, Bot::Stats.failed
    assert_requested(:post, "#{TELEGRAM_API}/editMessageText") { |req|
      Oj.load(req.body)["text"].include?("Could not fetch this media")
    }
    assert_requested(:post, "#{TELEGRAM_API}/sendMessage") { |req|
      body = Oj.load(req.body)
      body["chat_id"] == "123456" && body["text"].include?("Media transcription failed")
    }
  end

  private

  # Multipart bodies are binary; captions and titles are not.
  def utf8(body) = body.dup.force_encoding("UTF-8")

  def info(overrides = {})
    {
      "id" => "abc123", "extractor" => "youtube", "title" => "A talk",
      "duration" => 600, "live_status" => "not_live", "_type" => "video"
    }.merge(overrides)
  end

  def perform(duration: 600, info_overrides: {}, chunk_count: 1, auto_summarize: false,
              confirmed: false, message_id: MSG_ID)
    chunks = Array.new(chunk_count) do |i|
      path = File.join(@tmp_dir, format("chunk_%03d.ogg", i))
      File.write(path, "fake-chunk-bytes")
      path
    end

    downloader = FakeDownloader.new(info: info({ "duration" => duration }.merge(info_overrides)), chunks: chunks)
    Jobs::TranscribeMediaJob.stub(:make_downloader, downloader) do
      Jobs::TranscribeMediaJob.new.perform(CHAT_ID, message_id, URL, auto_summarize, confirmed)
    end
    downloader
  end
end
