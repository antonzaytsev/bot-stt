# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/bot/callback_handler"

class TestCallbackHandler < Minitest::Test
  ADMIN_ID = 123456
  GROUP_ID = -1009999

  def setup
    Sidekiq::Worker.clear_all
    Sidekiq.redis { |c| c.call("FLUSHDB") }
    ENV["ALLOWED_CHAT_ID"] = GROUP_ID.to_s

    stub_request(:post, "#{TELEGRAM_API}/answerCallbackQuery")
      .to_return(status: 200, body: Oj.dump({ "ok" => true, "result" => true }))
    stub_request(:post, "#{TELEGRAM_API}/editMessageReplyMarkup")
      .to_return(status: 200, body: Oj.dump({ "ok" => true, "result" => {} }))
  end

  def teardown
    super
    ENV.delete("ALLOWED_CHAT_ID")
  end

  def test_summarize_enqueues_the_job_and_answers
    Bot::TranscriptStore.save(token: "tok1", chat_id: ADMIN_ID, text: "Transcript.", source: "media")

    Bot::CallbackHandler.new(query(data: "s|tok1")).call

    assert_equal 1, Jobs::SummarizeJob.jobs.size
    assert_equal "tok1", Jobs::SummarizeJob.jobs.first["args"][0]
    assert_requested(:post, "#{TELEGRAM_API}/answerCallbackQuery") { |req|
      Oj.load(req.body)["text"].include?("Summarizing")
    }
  end

  def test_expired_transcript_answers_without_enqueuing
    Bot::CallbackHandler.new(query(data: "s|gone")).call

    assert_equal 0, Jobs::SummarizeJob.jobs.size
    assert_requested(:post, "#{TELEGRAM_API}/answerCallbackQuery") { |req|
      Oj.load(req.body)["text"].include?("expired")
    }
  end

  def test_proceed_enqueues_the_media_job_as_confirmed
    Bot::MediaCache.save_request("tok2", {
      "chat_id" => GROUP_ID, "message_id" => 42, "url" => "https://youtu.be/x", "auto_summarize" => false
    })

    Bot::CallbackHandler.new(query(data: "m|tok2", chat_id: GROUP_ID, chat_type: "supergroup", from_id: 777)).call

    assert_equal 1, Jobs::TranscribeMediaJob.jobs.size
    args = Jobs::TranscribeMediaJob.jobs.first["args"]
    assert_equal [GROUP_ID, 42, "https://youtu.be/x", false, true], args
  end

  def test_proceed_removes_the_keyboard
    Bot::MediaCache.save_request("tok2", {
      "chat_id" => GROUP_ID, "message_id" => 42, "url" => "https://youtu.be/x", "auto_summarize" => false
    })

    Bot::CallbackHandler.new(query(data: "m|tok2", chat_id: GROUP_ID, chat_type: "supergroup", from_id: 777)).call

    assert_requested(:post, "#{TELEGRAM_API}/editMessageReplyMarkup") { |req|
      body = Oj.load(req.body)
      body["message_id"] == 300 && body["reply_markup"].nil?
    }
  end

  # The button stays on screen until Telegram applies the edit, so a second tap
  # must not pay for the same two-hour podcast twice.
  def test_second_proceed_tap_enqueues_nothing
    Bot::MediaCache.save_request("tok2", {
      "chat_id" => GROUP_ID, "message_id" => 42, "url" => "https://youtu.be/x", "auto_summarize" => false
    })
    press = query(data: "m|tok2", chat_id: GROUP_ID, chat_type: "supergroup", from_id: 777)

    Bot::CallbackHandler.new(press).call
    Bot::CallbackHandler.new(press).call

    assert_equal 1, Jobs::TranscribeMediaJob.jobs.size
    assert_requested(:post, "#{TELEGRAM_API}/answerCallbackQuery") { |req|
      Oj.load(req.body)["text"].include?("expired")
    }
  end

  def test_expired_media_request_answers_without_enqueuing
    Bot::CallbackHandler.new(query(data: "m|gone")).call

    assert_equal 0, Jobs::TranscribeMediaJob.jobs.size
    assert_requested(:post, "#{TELEGRAM_API}/answerCallbackQuery") { |req|
      Oj.load(req.body)["text"].include?("expired")
    }
  end

  def test_press_from_a_stranger_in_a_private_chat_is_ignored
    Bot::TranscriptStore.save(token: "tok1", chat_id: 999, text: "Transcript.", source: "media")

    Bot::CallbackHandler.new(query(data: "s|tok1", chat_id: 999, from_id: 999)).call

    assert_equal 0, Jobs::SummarizeJob.jobs.size
    assert_requested(:post, "#{TELEGRAM_API}/answerCallbackQuery") { |req|
      Oj.load(req.body)["text"].include?("Not allowed")
    }
  end

  def test_press_in_an_unlisted_group_is_ignored
    Bot::TranscriptStore.save(token: "tok1", chat_id: -1008888, text: "Transcript.", source: "media")

    Bot::CallbackHandler.new(
      query(data: "s|tok1", chat_id: -1008888, chat_type: "supergroup", from_id: 777)
    ).call

    assert_equal 0, Jobs::SummarizeJob.jobs.size
  end

  def test_unknown_action_is_answered_and_does_not_raise
    Bot::CallbackHandler.new(query(data: "z|whatever")).call

    assert_requested(:post, "#{TELEGRAM_API}/answerCallbackQuery")
  end

  private

  def query(data:, chat_id: ADMIN_ID, chat_type: "private", from_id: ADMIN_ID)
    {
      "id" => "cb-1",
      "data" => data,
      "from" => { "id" => from_id },
      "message" => { "message_id" => 300, "chat" => { "id" => chat_id, "type" => chat_type } }
    }
  end
end
