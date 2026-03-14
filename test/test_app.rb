# frozen_string_literal: true

require_relative "test_helper"

class TestApp < Minitest::Test
  include Rack::Test::Methods

  def app
    App.freeze.app
  end

  def setup
    Sidekiq::Worker.clear_all
  end

  def test_health_returns_ok
    get "/health"
    assert_equal 200, last_response.status
    body = Oj.load(last_response.body)
    assert_equal "ok", body["status"]
  end

  def test_webhook_rejects_invalid_secret
    post "/webhook", Oj.dump({ "update_id" => 1 }), {
      "CONTENT_TYPE" => "application/json",
      "HTTP_X_TELEGRAM_BOT_API_SECRET_TOKEN" => "wrong-secret"
    }
    assert_equal 403, last_response.status
  end

  def test_webhook_rejects_missing_secret
    post "/webhook", Oj.dump({ "update_id" => 1 }), {
      "CONTENT_TYPE" => "application/json"
    }
    assert_equal 403, last_response.status
  end

  def test_webhook_accepts_valid_secret_and_enqueues_voice
    payload = {
      "update_id" => 1,
      "message" => {
        "message_id" => 42,
        "chat" => { "id" => -1001234 },
        "from" => { "id" => 999 },
        "voice" => { "file_id" => "abc123", "duration" => 5 }
      }
    }

    post "/webhook", Oj.dump(payload), {
      "CONTENT_TYPE" => "application/json",
      "HTTP_X_TELEGRAM_BOT_API_SECRET_TOKEN" => "test-secret"
    }

    assert_equal 200, last_response.status
    assert_equal 1, Jobs::TranscribeJob.jobs.size
  end

  def test_webhook_returns_ok_for_empty_update
    post "/webhook", Oj.dump({ "update_id" => 1 }), {
      "CONTENT_TYPE" => "application/json",
      "HTTP_X_TELEGRAM_BOT_API_SECRET_TOKEN" => "test-secret"
    }

    assert_equal 200, last_response.status
    assert_equal 0, Jobs::TranscribeJob.jobs.size
  end

  def test_unknown_route_returns_404
    get "/nonexistent"
    assert_equal 404, last_response.status
  end
end
