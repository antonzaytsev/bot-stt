# frozen_string_literal: true

ENV["RACK_ENV"] = "test"
ENV["TELEGRAM_BOT_TOKEN"] = "test-bot-token"
ENV["OPENAI_API_KEY"] = "test-openai-key"
ENV["ADMIN_CHAT_ID"] = "123456"
ENV["REDIS_URL"] = "redis://localhost:6379/15"
ENV["WEBHOOK_SECRET"] = "test-secret"
ENV["PORT"] = "3000"

require "minitest/autorun"
require "webmock/minitest"
require "rack/test"
require "sidekiq/testing"

Sidekiq::Testing.fake!

require_relative "../app"

TELEGRAM_API = "https://api.telegram.org/bottest-bot-token"
