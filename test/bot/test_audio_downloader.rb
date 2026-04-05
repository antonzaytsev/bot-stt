# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/bot/audio_downloader"

class TestAudioDownloader < Minitest::Test
  def test_valid_url_accepts_yandex_music_ru
    assert Bot::AudioDownloader.valid_url?("https://music.yandex.ru/album/9294155/track/12345")
  end

  def test_valid_url_accepts_yandex_music_com
    assert Bot::AudioDownloader.valid_url?("https://music.yandex.com/album/9294155")
  end

  def test_valid_url_rejects_other_domains
    refute Bot::AudioDownloader.valid_url?("https://example.com/podcast")
  end

  def test_valid_url_rejects_non_urls
    refute Bot::AudioDownloader.valid_url?("not a url")
  end
end
