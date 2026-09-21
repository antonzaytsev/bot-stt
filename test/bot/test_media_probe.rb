# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/bot/media_probe"

class TestMediaProbe < Minitest::Test
  def test_normalizes_a_regular_video
    result = probe(
      "id" => "abc123", "extractor" => "youtube", "extractor_key" => "Youtube",
      "title" => "A talk", "duration" => 1234.7, "live_status" => "not_live", "_type" => "video"
    )

    assert_equal "abc123", result.id
    assert_equal "youtube", result.extractor
    assert_equal "A talk", result.title
    assert_equal 1234, result.duration
    refute result.live?
    refute result.playlist?
    assert_nil result.refusal
  end

  def test_live_stream_is_refused
    result = probe("id" => "x", "live_status" => "is_live")

    assert result.live?
    assert_match(/Live streams/, result.refusal)
  end

  def test_upcoming_premiere_is_refused
    assert probe("id" => "x", "live_status" => "is_upcoming").live?
  end

  def test_finished_stream_is_processable
    refute probe("id" => "x", "live_status" => "post_live", "duration" => 60).live?
  end

  def test_playlist_is_refused
    result = probe("_type" => "playlist", "id" => "PL123", "title" => "Some list")

    assert result.playlist?
    assert_match(/Playlists/, result.refusal)
  end

  def test_missing_duration_stays_nil
    assert_nil probe("id" => "x").duration
  end

  private

  def probe(info)
    downloader = Object.new
    downloader.define_singleton_method(:probe) { |_url| info }
    Bot::MediaProbe.new(downloader: downloader).call("https://youtu.be/x")
  end
end
