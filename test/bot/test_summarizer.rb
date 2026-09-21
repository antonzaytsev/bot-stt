# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/bot/summarizer"

class TestSummarizer < Minitest::Test
  # Records what the summarizer asks the model, so the map-reduce shape is
  # visible without any HTTP.
  class FakeWhisper
    attr_reader :calls

    def initialize(reply: "Summary.")
      @calls = []
      @reply = reply
    end

    def chat(system_prompt, user_content, model: "gpt-4o-mini", timeout: 60)
      @calls << { system: system_prompt, user: user_content, model: model }
      @reply
    end
  end

  def test_short_transcript_is_summarized_in_one_call
    whisper = FakeWhisper.new
    result = Bot::Summarizer.new(whisper: whisper, model: "gpt-4o").call("A short transcript.", title: "A talk")

    assert_equal "Summary.", result
    assert_equal 1, whisper.calls.length
    assert_equal "gpt-4o", whisper.calls[0][:model]
    assert_includes whisper.calls[0][:user], "Title: A talk"
    assert_includes whisper.calls[0][:user], "A short transcript."
  end

  def test_long_transcript_maps_then_reduces
    whisper = FakeWhisper.new
    transcript = (["paragraph " * 200] * 40).join("\n\n")

    Bot::Summarizer.new(whisper: whisper, model: "gpt-4o").call(transcript)

    assert_operator whisper.calls.length, :>, 2
    notes_calls = whisper.calls[0..-2]
    assert notes_calls.all? { |c| c[:model] == "gpt-4o-mini" }
    assert notes_calls.all? { |c| c[:system].include?("taking notes") }

    final = whisper.calls.last
    assert_equal "gpt-4o", final[:model]
    assert_includes final[:user], "Notes taken from the full transcript"
  end

  def test_map_windows_stay_within_the_limit
    whisper = FakeWhisper.new
    transcript = (["paragraph " * 200] * 40).join("\n\n")

    Bot::Summarizer.new(whisper: whisper).call(transcript)

    windows = whisper.calls[0..-2].map { |c| c[:user] }
    assert windows.all? { |w| w.length <= Bot::Summarizer::WINDOW_CHARS * 2 }
  end

  def test_progress_is_reported_for_each_window
    reported = []
    transcript = (["paragraph " * 200] * 40).join("\n\n")

    Bot::Summarizer.new(whisper: FakeWhisper.new, progress: ->(msg) { reported << msg }).call(transcript)

    assert reported.any? { |m| m.start_with?("Summarizing part 1/") }
    assert_includes reported, "Writing the summary..."
  end

  def test_empty_transcript_returns_nil_without_calling_the_model
    whisper = FakeWhisper.new

    assert_nil Bot::Summarizer.new(whisper: whisper).call("   ")
    assert_empty whisper.calls
  end
end
