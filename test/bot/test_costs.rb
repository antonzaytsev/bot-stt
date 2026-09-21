# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/bot/costs"

class TestCosts < Minitest::Test
  def test_audio_is_priced_per_minute
    assert_in_delta 0.06, Bot::Costs.audio(600), 0.0001
    assert_equal 0.0, Bot::Costs.audio(nil)
  end

  def test_chat_uses_the_model_price
    cost = Bot::Costs.chat(model: "gpt-4o", input_tokens: 1_000_000, output_tokens: 0)
    assert_in_delta 2.50, cost, 0.0001

    mini = Bot::Costs.chat(model: "gpt-4o-mini", input_tokens: 0, output_tokens: 1_000_000)
    assert_in_delta 0.60, mini, 0.0001
  end

  def test_unknown_models_fall_back_to_the_full_price
    assert_in_delta Bot::Costs.chat(model: "gpt-4o", input_tokens: 1000, output_tokens: 500),
      Bot::Costs.chat(model: "gpt-9-imaginary", input_tokens: 1000, output_tokens: 500), 0.0001
  end

  # A real charge rounded to $0.00 reads as free, which is the one claim the
  # number exists to disprove.
  def test_tiny_amounts_are_not_shown_as_zero
    assert_equal "<$0.01", Bot::Costs.format(0.0004)
    assert_equal "$0.00", Bot::Costs.format(0)
    assert_equal "$0.14", Bot::Costs.format(0.1449)
  end
end
