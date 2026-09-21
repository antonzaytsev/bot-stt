# frozen_string_literal: true

require "sidekiq"
require "oj"
require "digest"

module Bot
  # Transcripts and summaries keyed by media identity rather than by message, so
  # the same video or podcast costs money once no matter who posts it or how the
  # URL is written. yt-dlp's extractor+id pair survives URL variation
  # (youtu.be/X, watch?v=X and shorts/X all collapse to youtube:X).
  module MediaCache
    TRANSCRIPT_PREFIX = "media_transcript:"
    SUMMARY_PREFIX = "media_summary:"
    REQUEST_PREFIX = "media_request:"
    TTL = 90 * 24 * 3600 # 90 days, refreshed on every hit
    REQUEST_TTL = 7 * 24 * 3600

    class << self
      def key_for(extractor:, id:, url: nil)
        return "#{extractor || "generic"}:#{id}" unless id.to_s.empty?

        "generic:#{Digest::SHA256.hexdigest(url.to_s)[0, 16]}"
      end

      def fetch_transcript(key)
        fetch(TRANSCRIPT_PREFIX + key)
      end

      def save_transcript(key, text:, title: nil, duration: nil)
        write(TRANSCRIPT_PREFIX + key, { "text" => text, "title" => title, "duration" => duration })
      end

      # A pending long-media confirmation: the Proceed button can only carry 64
      # bytes, so the URL and what we already know about it wait here.
      def save_request(token, record)
        Sidekiq.redis { |c| c.call("SET", REQUEST_PREFIX + token, Oj.dump(record), "EX", REQUEST_TTL) }
        record
      end

      def fetch_request(token)
        raw = Sidekiq.redis { |c| c.call("GET", REQUEST_PREFIX + token) }
        raw && Oj.load(raw)
      end

      # Single-use: only the first tap of a Proceed button gets the request.
      def take_request(token)
        raw = Sidekiq.redis { |c| c.call("GETDEL", REQUEST_PREFIX + token) }
        raw && Oj.load(raw)
      end

      def fetch_summary(key)
        record = fetch(SUMMARY_PREFIX + key)
        record && record["text"]
      end

      def save_summary(key, text)
        write(SUMMARY_PREFIX + key, { "text" => text })
      end

      private

      def fetch(redis_key)
        raw = Sidekiq.redis { |c| c.call("GET", redis_key) }
        return nil unless raw

        Sidekiq.redis { |c| c.call("EXPIRE", redis_key, TTL) }
        Oj.load(raw)
      end

      def write(redis_key, record)
        Sidekiq.redis { |c| c.call("SET", redis_key, Oj.dump(record), "EX", TTL) }
        record
      end
    end
  end
end
