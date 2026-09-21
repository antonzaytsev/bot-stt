# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/bot/transcript_delivery"

class TestTranscriptDelivery < Minitest::Test
  CHAT_ID = -1001234
  MSG_ID = 42
  STATUS_MSG_ID = 300

  def setup
    Sidekiq.redis { |c| c.call("FLUSHDB") }

    stub_request(:post, "#{TELEGRAM_API}/sendMessage")
      .to_return(status: 200, body: Oj.dump({ "ok" => true, "result" => { "message_id" => 500 } }))
    stub_request(:post, "#{TELEGRAM_API}/editMessageText")
      .to_return(status: 200, body: Oj.dump({ "ok" => true, "result" => {} }))
    stub_request(:post, "#{TELEGRAM_API}/sendDocument")
      .to_return(status: 200, body: Oj.dump({ "ok" => true, "result" => { "message_id" => 501 } }))
  end

  def test_short_transcript_edits_the_status_message
    result = deliver(text: "Short text.", status_msg_id: STATUS_MSG_ID)

    assert_equal STATUS_MSG_ID, result[:anchor_msg_id]
    assert_requested(:post, "#{TELEGRAM_API}/editMessageText") { |req|
      Oj.load(req.body)["text"] == "Short text."
    }
    assert_not_requested(:post, "#{TELEGRAM_API}/sendDocument")
  end

  def test_short_transcript_without_a_status_message_replies
    result = deliver(text: "Short text.")

    assert_equal 500, result[:anchor_msg_id]
    assert_requested(:post, "#{TELEGRAM_API}/sendMessage") { |req|
      body = Oj.load(req.body)
      body["reply_to_message_id"] == MSG_ID && body["text"] == "Short text."
    }
  end

  def test_long_transcript_is_sent_as_a_file
    result = deliver(text: "word " * 1000, base_name: "my talk.mp3", status_msg_id: STATUS_MSG_ID)

    assert_equal 501, result[:anchor_msg_id]
    assert_requested(:post, "#{TELEGRAM_API}/sendDocument") { |req|
      req.body.include?("filename=\"my talk.txt\"")
    }
    assert_requested(:post, "#{TELEGRAM_API}/editMessageText") { |req|
      Oj.load(req.body)["text"].include?("sent as a file")
    }
  end

  def test_force_file_sends_a_short_transcript_as_a_file_too
    deliver(text: "Short text.", force_file: true, base_name: "clip")

    assert_requested(:post, "#{TELEGRAM_API}/sendDocument")
  end

  def test_summary_button_carries_the_token_and_the_record_is_stored
    text = "word " * 400
    result = deliver(text: text, status_msg_id: STATUS_MSG_ID, title: "A talk", media_key: "youtube:abc")

    assert_requested(:post, "#{TELEGRAM_API}/editMessageText") { |req|
      markup = Oj.load(req.body)["reply_markup"]
      markup && markup["inline_keyboard"][0][0]["callback_data"] == "s|#{result[:token]}"
    }

    record = Bot::TranscriptStore.fetch(result[:token])
    assert_equal text, record["text"]
    assert_equal CHAT_ID, record["chat_id"]
    assert_equal STATUS_MSG_ID, record["anchor_msg_id"]
    assert_equal "youtube:abc", record["media_key"]
    assert_equal "A talk", record["title"]
    assert_equal true, record["button"]
  end

  def test_no_button_below_the_summary_threshold
    result = deliver(text: "Too short to summarize.", status_msg_id: STATUS_MSG_ID)

    assert_requested(:post, "#{TELEGRAM_API}/editMessageText") { |req|
      Oj.load(req.body)["reply_markup"].nil?
    }
    assert_equal false, Bot::TranscriptStore.fetch(result[:token])["button"]
  end

  def test_button_can_be_suppressed_explicitly
    deliver(text: "word " * 400, status_msg_id: STATUS_MSG_ID, button: false)

    assert_requested(:post, "#{TELEGRAM_API}/editMessageText") { |req|
      Oj.load(req.body)["reply_markup"].nil?
    }
  end

  def test_file_name_falls_back_and_is_sanitized
    deliver(text: "word " * 1000, base_name: "a/b: weird \"name\"")

    assert_requested(:post, "#{TELEGRAM_API}/sendDocument") { |req|
      req.body.include?("filename=\"b weird name.txt\"")
    }
  end

  # Ruby's \w is ASCII-only, so a naive sanitizer erases a Cyrillic title
  # entirely and every such video arrives as transcript.txt.
  def test_non_ascii_titles_survive_sanitizing
    assert_equal "Интервью с Дуровым", Bot::TranscriptDelivery.sanitize_name("Интервью с Дуровым")
    assert_equal "転職 (2024)", Bot::TranscriptDelivery.sanitize_name("転職 (2024)")
    assert_equal "transcript", Bot::TranscriptDelivery.sanitize_name("///")
  end

  def test_long_names_are_truncated
    assert_equal 80, Bot::TranscriptDelivery.sanitize_name("a" * 200).length
  end

  private

  def deliver(text:, source: "audio", **kwargs)
    Bot::TranscriptDelivery.new(
      telegram: Bot::TelegramClient.new, chat_id: CHAT_ID, reply_to_message_id: MSG_ID
    ).call(text: text, source: source, **kwargs)
  end
end
