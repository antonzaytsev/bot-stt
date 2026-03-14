# frozen_string_literal: true

require_relative "test_helper"

class TestApp < Minitest::Test
  include Rack::Test::Methods

  def app
    App.freeze.app
  end

  def test_health_returns_ok
    get "/health"
    assert_equal 200, last_response.status
    body = Oj.load(last_response.body)
    assert_equal "ok", body["status"]
  end

  def test_unknown_route_returns_404
    get "/nonexistent"
    assert_equal 404, last_response.status
  end
end
