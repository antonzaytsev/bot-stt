# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/jobs/podcast_job"

class TestPodcastJob < Minitest::Test
  def setup
    Sidekiq::Worker.clear_all
    Sidekiq.redis { |c| c.call("FLUSHDB") }

    @status_msg_stub = stub_request(:post, "#{TELEGRAM_API}/sendMessage")
      .to_return(status: 200, body: Oj.dump({ "ok" => true, "result" => { "message_id" => 200 } }))

    @edit_stub = stub_request(:post, "#{TELEGRAM_API}/editMessageText")
      .to_return(status: 200, body: Oj.dump({ "ok" => true, "result" => {} }))

    stub_request(:post, "https://api.openai.com/v1/audio/transcriptions")
      .to_return(status: 200, body: Oj.dump({ "text" => "Chunk transcription." }))

    stub_request(:post, "https://api.openai.com/v1/chat/completions")
      .to_return(status: 200, body: Oj.dump({
        "choices" => [{ "message" => { "content" => "- Key point one\n- Key point two" } }]
      }))
  end

  def test_happy_path_sends_status_then_edits_with_summary
    fake_downloader = Minitest::Mock.new
    tmp_dir = Dir.mktmpdir("podcast_test")
    chunk_file = File.join(tmp_dir, "chunk_000.ogg")
    File.write(chunk_file, "fake-audio-bytes")
    audio_file = File.join(tmp_dir, "audio.opus")
    File.write(audio_file, "fake-audio")

    fake_downloader.expect(:download, audio_file) { |url, **kw| url.is_a?(String) && kw.key?(:output_dir) }
    fake_downloader.expect(:split_audio, [chunk_file]) { |path, **kw| path == audio_file }

    Jobs::PodcastJob.stub(:make_downloader, fake_downloader) do
      Jobs::PodcastJob.new.perform("123456", "https://music.yandex.ru/album/123/track/456")
    end

    assert_requested(:post, "#{TELEGRAM_API}/sendMessage") { |req|
      body = Oj.load(req.body)
      body["text"].include?("Downloading")
    }
    assert_requested(:post, "#{TELEGRAM_API}/editMessageText") { |req|
      body = Oj.load(req.body)
      body["message_id"] == 200 && body["text"].include?("Key point")
    }

    fake_downloader.verify
    FileUtils.remove_entry(tmp_dir)
  end

  def test_edits_status_with_error_on_failure
    fake_downloader = Object.new
    def fake_downloader.download(url, output_dir:)
      raise "yt-dlp failed"
    end

    Jobs::PodcastJob.stub(:make_downloader, fake_downloader) do
      assert_raises(RuntimeError) do
        Jobs::PodcastJob.new.perform("123456", "https://music.yandex.ru/album/123/track/456")
      end
    end

    assert_requested(:post, "#{TELEGRAM_API}/editMessageText") { |req|
      body = Oj.load(req.body)
      body["text"].include?("Failed")
    }
  end
end
