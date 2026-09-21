# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/jobs/summarize_job"

class TestSummarizeJob < Minitest::Test
  CHAT_ID = -1001234
  ANCHOR_MSG_ID = 301
  STATUS_MSG_ID = 400

  def setup
    Sidekiq::Worker.clear_all
    Sidekiq.redis { |c| c.call("FLUSHDB") }

    stub_request(:post, "#{TELEGRAM_API}/sendMessage")
      .to_return(status: 200, body: Oj.dump({ "ok" => true, "result" => { "message_id" => STATUS_MSG_ID } }))
    stub_request(:post, "#{TELEGRAM_API}/editMessageText")
      .to_return(status: 200, body: Oj.dump({ "ok" => true, "result" => {} }))
    stub_request(:post, "#{TELEGRAM_API}/editMessageReplyMarkup")
      .to_return(status: 200, body: Oj.dump({ "ok" => true, "result" => {} }))
    stub_request(:post, "#{TELEGRAM_API}/sendDocument")
      .to_return(status: 200, body: Oj.dump({ "ok" => true, "result" => { "message_id" => 302 } }))
    stub_request(:post, "https://api.openai.com/v1/chat/completions")
      .to_return(status: 200, body: Oj.dump({
        "choices" => [{ "message" => { "content" => "TL;DR it was good." } }],
        "usage" => { "prompt_tokens" => 10_000, "completion_tokens" => 1_000 }
      }))
  end

  def test_summarizes_and_edits_the_status_message
    save_transcript

    Jobs::SummarizeJob.new.perform("tok")

    assert_requested(:post, "https://api.openai.com/v1/chat/completions", times: 1)
    assert_requested(:post, "#{TELEGRAM_API}/editMessageText") { |req|
      body = Oj.load(req.body)
      body["message_id"] == STATUS_MSG_ID && body["text"].start_with?("TL;DR it was good.")
    }
  end

  # The models answer in Markdown, which Telegram shows as literal asterisks
  # unless the message declares a parse mode.
  def test_markdown_is_converted_to_telegram_html
    save_transcript
    stub_request(:post, "https://api.openai.com/v1/chat/completions")
      .to_return(status: 200, body: Oj.dump({
        "choices" => [{ "message" => { "content" => "**TL;DR**\n- Платформа для агентов" } }]
      }))

    Jobs::SummarizeJob.new.perform("tok")

    assert_requested(:post, "#{TELEGRAM_API}/editMessageText") { |req|
      body = Oj.load(req.body)
      body["parse_mode"] == "HTML" &&
        body["text"].include?("<b>TL;DR</b>") && body["text"].include?("• Платформа для агентов")
    }
  end

  # Telegram rejects the whole message if it dislikes one entity; an unformatted
  # summary beats no summary.
  def test_rejected_formatting_is_retried_unformatted
    save_transcript
    stub_request(:post, "#{TELEGRAM_API}/editMessageText")
      .with { |req| Oj.load(req.body)["parse_mode"] == "HTML" }
      .to_return(status: 200, body: Oj.dump({ "ok" => false, "description" => "Bad Request: can't parse entities" }))

    Jobs::SummarizeJob.new.perform("tok")

    assert_requested(:post, "#{TELEGRAM_API}/editMessageText") { |req|
      Oj.load(req.body)["parse_mode"] == "HTML"
    }
    assert_requested(:post, "#{TELEGRAM_API}/editMessageText") { |req|
      body = Oj.load(req.body)
      body["parse_mode"].nil? && body["text"].start_with?("TL;DR it was good.")
    }
  end

  def test_summary_carries_its_cost
    save_transcript

    Jobs::SummarizeJob.new.perform("tok")

    assert_requested(:post, "#{TELEGRAM_API}/editMessageText") { |req|
      Oj.load(req.body)["text"].include?("Cost: $0.04")
    }
  end

  def test_cost_line_adds_the_transcription_that_produced_the_transcript
    save_transcript(cost: 0.12)

    Jobs::SummarizeJob.new.perform("tok")

    assert_requested(:post, "#{TELEGRAM_API}/editMessageText") { |req|
      text = Oj.load(req.body)["text"]
      text.include?("Cost: $0.16") && text.include?("transcript $0.12") && text.include?("summary $0.04")
    }
  end

  def test_removes_the_summarize_button_from_the_anchor
    save_transcript

    Jobs::SummarizeJob.new.perform("tok")

    assert_requested(:post, "#{TELEGRAM_API}/editMessageReplyMarkup") { |req|
      body = Oj.load(req.body)
      body["message_id"] == ANCHOR_MSG_ID && body["reply_markup"].nil?
    }
  end

  def test_second_tap_does_not_summarize_again
    save_transcript

    Jobs::SummarizeJob.new.perform("tok")
    Jobs::SummarizeJob.new.perform("tok")

    assert_requested(:post, "https://api.openai.com/v1/chat/completions", times: 1)
  end

  def test_cached_summary_skips_the_model
    save_transcript(media_key: "youtube:x")
    Bot::MediaCache.save_summary("youtube:x", "Cached summary.")

    Jobs::SummarizeJob.new.perform("tok")

    assert_not_requested(:post, "https://api.openai.com/v1/chat/completions")
    assert_requested(:post, "#{TELEGRAM_API}/sendMessage") { |req|
      body = Oj.load(req.body)
      body["text"].start_with?("Cached summary.") && body["text"].include?("no new cost") &&
        body["reply_to_message_id"] == ANCHOR_MSG_ID
    }
  end

  def test_summary_is_cached_for_media
    save_transcript(media_key: "youtube:x")

    Jobs::SummarizeJob.new.perform("tok")

    assert_equal "TL;DR it was good.", Bot::MediaCache.fetch_summary("youtube:x")
  end

  def test_long_summary_is_sent_as_a_file
    save_transcript(media_key: nil, title: "A talk")
    stub_request(:post, "https://api.openai.com/v1/chat/completions")
      .to_return(status: 200, body: Oj.dump({ "choices" => [{ "message" => { "content" => "word " * 1000 } }] }))

    Jobs::SummarizeJob.new.perform("tok")

    assert_requested(:post, "#{TELEGRAM_API}/sendDocument") { |req|
      req.body.include?("filename=\"A talk-summary.txt\"")
    }
  end

  def test_expired_transcript_is_a_no_op
    Jobs::SummarizeJob.new.perform("gone")

    assert_not_requested(:post, "https://api.openai.com/v1/chat/completions")
    assert_not_requested(:post, "#{TELEGRAM_API}/sendMessage")
  end

  def test_failure_releases_the_lock_and_reports
    save_transcript
    stub_request(:post, "https://api.openai.com/v1/chat/completions")
      .to_return(status: 500, body: Oj.dump({ "error" => { "message" => "LLM down" } }))

    assert_raises(RuntimeError) { Jobs::SummarizeJob.new.perform("tok") }

    assert_equal 0, Sidekiq.redis { |c| c.call("EXISTS", "summarizing:tok") }
    assert_requested(:post, "#{TELEGRAM_API}/editMessageText") { |req|
      Oj.load(req.body)["text"].include?("Summary failed")
    }
  end

  private

  def save_transcript(media_key: nil, title: "A talk", text: "The transcript body.", cost: nil)
    Bot::TranscriptStore.save(
      token: "tok", chat_id: CHAT_ID, anchor_msg_id: ANCHOR_MSG_ID, text: text,
      source: "media", title: title, media_key: media_key, button: true, cost: cost
    )
  end
end
