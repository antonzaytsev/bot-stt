# frozen_string_literal: true

module Bot
  # What a job actually cost at OpenAI list prices. Transcription is billed by
  # audio minute; the formatting and summary passes are billed by token, and the
  # API returns the token counts, so those are measured rather than estimated.
  module Costs
    TRANSCRIBE_PER_MINUTE = 0.006

    # USD per million tokens.
    CHAT = {
      "gpt-4o" => { input: 2.50, output: 10.00 },
      "gpt-4o-mini" => { input: 0.15, output: 0.60 },
      "gpt-4.1" => { input: 2.00, output: 8.00 },
      "gpt-4.1-mini" => { input: 0.40, output: 1.60 }
    }.freeze
    DEFAULT_CHAT_PRICE = { input: 2.50, output: 10.00 }.freeze

    class << self
      def audio(seconds)
        return 0.0 if seconds.nil?

        (seconds.to_f / 60.0) * TRANSCRIBE_PER_MINUTE
      end

      def chat(model:, input_tokens:, output_tokens:)
        price = CHAT[model] || DEFAULT_CHAT_PRICE
        (input_tokens.to_i * price[:input] + output_tokens.to_i * price[:output]) / 1_000_000.0
      end

      # Rounding a real charge down to $0.00 reads like "this was free", which is
      # the one thing the number is there to disprove.
      def format(usd)
        usd = usd.to_f
        return "$0.00" if usd.zero?
        return "<$0.01" if usd < 0.005

        "$#{"%.2f" % usd}"
      end
    end
  end
end
