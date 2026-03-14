# frozen_string_literal: true

require_relative "../test_helper"

class TestCommandHandler < Minitest::Test
  ADMIN_ID = "123456"
  NON_ADMIN_ID = "999999"

  def setup
    stub_request(:post, "#{TELEGRAM_API}/sendMessage")
      .to_return(status: 200, body: Oj.dump({ "ok" => true, "result" => {} }))
  end

  def test_ping_replies_pong
    Bot::CommandHandler.call(command: "/ping", user_id: ADMIN_ID, chat_id: ADMIN_ID)

    assert_requested(:post, "#{TELEGRAM_API}/sendMessage") { |req|
      body = Oj.load(req.body)
      body["text"] == "pong" && body["chat_id"] == ADMIN_ID
    }
  end

  def test_help_lists_commands
    Bot::CommandHandler.call(command: "/help", user_id: ADMIN_ID, chat_id: ADMIN_ID)

    assert_requested(:post, "#{TELEGRAM_API}/sendMessage") { |req|
      body = Oj.load(req.body)
      body["text"].include?("/ping") && body["text"].include?("/status")
    }
  end

  def test_stats_shows_counters
    Bot::Stats.instance_variable_set(:@processed, 5)
    Bot::Stats.instance_variable_set(:@failed, 2)
    Bot::Stats.instance_variable_set(:@last_reset_date, Date.today)

    Bot::CommandHandler.call(command: "/stats", user_id: ADMIN_ID, chat_id: ADMIN_ID)

    assert_requested(:post, "#{TELEGRAM_API}/sendMessage") { |req|
      body = Oj.load(req.body)
      body["text"].include?("Processed: 5") && body["text"].include?("Failed: 2")
    }
  end

  def test_status_includes_uptime_and_redis
    Bot::CommandHandler.call(command: "/status", user_id: ADMIN_ID, chat_id: ADMIN_ID)

    assert_requested(:post, "#{TELEGRAM_API}/sendMessage") { |req|
      body = Oj.load(req.body)
      body["text"].include?("Uptime:") && body["text"].include?("Redis:")
    }
  end

  def test_ignores_non_admin_user
    Bot::CommandHandler.call(command: "/ping", user_id: NON_ADMIN_ID, chat_id: NON_ADMIN_ID)
    assert_not_requested(:post, "#{TELEGRAM_API}/sendMessage")
  end

  def test_ignores_unknown_command
    Bot::CommandHandler.call(command: "/unknown", user_id: ADMIN_ID, chat_id: ADMIN_ID)
    assert_not_requested(:post, "#{TELEGRAM_API}/sendMessage")
  end

  def test_replies_to_admin_privately
    Bot::CommandHandler.call(command: "/ping", user_id: ADMIN_ID, chat_id: "-1001234")

    assert_requested(:post, "#{TELEGRAM_API}/sendMessage") { |req|
      body = Oj.load(req.body)
      body["chat_id"] == ADMIN_ID
    }
  end
end
