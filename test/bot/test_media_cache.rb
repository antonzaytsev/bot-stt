# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/bot/media_cache"

class TestMediaCache < Minitest::Test
  def setup
    Sidekiq.redis { |c| c.call("FLUSHDB") }
  end

  def test_key_combines_extractor_and_id
    assert_equal "youtube:dQw4w9WgXcQ",
      Bot::MediaCache.key_for(extractor: "youtube", id: "dQw4w9WgXcQ", url: "https://youtu.be/dQw4w9WgXcQ")
  end

  def test_key_falls_back_to_a_url_hash_without_an_id
    key = Bot::MediaCache.key_for(extractor: "generic", id: nil, url: "https://example.com/ep.mp3")

    assert_match(/\Ageneric:[0-9a-f]{16}\z/, key)
    assert_equal key, Bot::MediaCache.key_for(extractor: "generic", id: "", url: "https://example.com/ep.mp3")
  end

  def test_transcript_round_trip_keeps_title_and_duration
    Bot::MediaCache.save_transcript("youtube:x", text: "Hello.", title: "A talk", duration: 90)

    record = Bot::MediaCache.fetch_transcript("youtube:x")
    assert_equal "Hello.", record["text"]
    assert_equal "A talk", record["title"]
    assert_equal 90, record["duration"]
  end

  def test_missing_entries_are_nil
    assert_nil Bot::MediaCache.fetch_transcript("youtube:nope")
    assert_nil Bot::MediaCache.fetch_summary("youtube:nope")
    assert_nil Bot::MediaCache.fetch_request("nope")
  end

  def test_summary_round_trip
    Bot::MediaCache.save_summary("youtube:x", "TL;DR ...")

    assert_equal "TL;DR ...", Bot::MediaCache.fetch_summary("youtube:x")
  end

  def test_reading_refreshes_the_ttl
    Bot::MediaCache.save_transcript("youtube:x", text: "Hello.")
    Sidekiq.redis { |c| c.call("EXPIRE", "media_transcript:youtube:x", 60) }

    Bot::MediaCache.fetch_transcript("youtube:x")

    ttl = Sidekiq.redis { |c| c.call("TTL", "media_transcript:youtube:x") }
    assert_operator ttl, :>, 60
  end

  def test_pending_request_round_trip
    Bot::MediaCache.save_request("tok", { "url" => "https://youtu.be/x", "duration" => 7200 })

    record = Bot::MediaCache.fetch_request("tok")
    assert_equal "https://youtu.be/x", record["url"]
    assert_equal 7200, record["duration"]
  end
end
