# frozen_string_literal: true

require_relative "config/environment"
require_relative "lib/bot/telegram_client"

require "rake/testtask"

Rake::TestTask.new do |t|
  t.pattern = "test/**/test_*.rb"
  t.warning = false
end

task default: :test

namespace :bot do
  desc "Register Telegram webhook (requires WEBHOOK_URL env var)"
  task :set_webhook do
    webhook_url = ENV.fetch("WEBHOOK_URL") do
      abort "Set WEBHOOK_URL to your public URL, e.g. https://example.com/webhook"
    end

    client = Bot::TelegramClient.new
    result = client.set_webhook(url: webhook_url, secret_token: Config["WEBHOOK_SECRET"])
    puts "Webhook set: #{result}"
  end
end
