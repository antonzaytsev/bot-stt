# frozen_string_literal: true

require "sidekiq"
require "oj"
require "securerandom"

module Bot
  # Per-delivery transcript records, addressed by a short token that also travels
  # in the Summarize button's callback data (Telegram caps that payload at 64
  # bytes, so the text itself can never go there).
  module TranscriptStore
    PREFIX = "transcript:"
    TTL = 30 * 24 * 3600 # 30 days

    class << self
      def new_token
        SecureRandom.hex(6)
      end

      def save(token:, chat_id:, text:, source:, anchor_msg_id: nil, title: nil, media_key: nil,
               button: false, cost: nil)
        record = {
          "chat_id" => chat_id,
          "anchor_msg_id" => anchor_msg_id,
          "text" => text,
          "source" => source,
          "title" => title,
          "media_key" => media_key,
          "button" => button,
          "cost" => cost
        }
        Sidekiq.redis { |c| c.call("SET", PREFIX + token, Oj.dump(record), "EX", TTL) }
        record
      end

      def fetch(token)
        raw = Sidekiq.redis { |c| c.call("GET", PREFIX + token) }
        raw && Oj.load(raw)
      end

      # After a 👎 re-transcription, a later Summarize should work from the text
      # the user actually sees.
      def update_text(token, text)
        record = fetch(token)
        return nil unless record

        record["text"] = text
        Sidekiq.redis { |c| c.call("SET", PREFIX + token, Oj.dump(record), "KEEPTTL") }
        record
      end
    end
  end
end
