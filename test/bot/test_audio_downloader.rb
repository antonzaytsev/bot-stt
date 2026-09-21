# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/bot/audio_downloader"

class TestAudioDownloader < Minitest::Test
  def test_valid_url_accepts_yandex_music
    assert Bot::AudioDownloader.valid_url?("https://music.yandex.ru/album/9294155/track/12345")
  end

  def test_valid_url_accepts_apple_podcasts
    assert Bot::AudioDownloader.valid_url?("https://podcasts.apple.com/us/podcast/example/id123?i=456")
  end

  def test_valid_url_accepts_any_http_url
    assert Bot::AudioDownloader.valid_url?("https://example.com/podcast")
  end

  def test_valid_url_rejects_non_urls
    refute Bot::AudioDownloader.valid_url?("not a url")
  end

  def test_probe_parses_the_json_line_among_warnings
    downloader = Bot::AudioDownloader.new
    output = "WARNING: No supported JavaScript runtime\n{\"id\": \"abc\", \"duration\": 12}\n"
    downloader.define_singleton_method(:run_command) { |*_cmd| output }

    info = downloader.probe("https://youtu.be/abc")

    assert_equal "abc", info["id"]
    assert_equal 12, info["duration"]
  end

  def test_probe_raises_when_there_is_no_metadata
    downloader = Bot::AudioDownloader.new
    downloader.define_singleton_method(:run_command) { |*_cmd| "WARNING: something\n" }

    assert_raises(RuntimeError) { downloader.probe("https://youtu.be/abc") }
  end
end
