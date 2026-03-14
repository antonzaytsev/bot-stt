# frozen_string_literal: true

require "roda"
require "oj"
require "logger"
require_relative "config/environment"
require_relative "config/sidekiq"
require_relative "lib/bot/telegram_client"
require_relative "lib/bot/command_handler"
require_relative "lib/bot/webhook_handler"

class App < Roda
  plugin :json
  plugin :json_parser, parser: ->(body) { Oj.load(body) }

  LOGGER = Logger.new($stdout)
  LOGGER.formatter = proc { |severity, time, _, msg| "#{time.utc.iso8601} #{severity} #{msg}\n" }

  route do |r|
    r.get "health" do
      { status: "ok" }
    end

    r.post "webhook" do
      secret = r.env["HTTP_X_TELEGRAM_BOT_API_SECRET_TOKEN"]
      unless secret == Config["WEBHOOK_SECRET"]
        LOGGER.warn("Webhook rejected: invalid secret token")
        response.status = 403
        next { error: "forbidden" }
      end

      LOGGER.info("Webhook received: update_id=#{r.params["update_id"]}")
      Bot::WebhookHandler.new(r.params).call

      { status: "ok" }
    end
  end
end
