# frozen_string_literal: true

require "roda"
require "oj"
require_relative "config/environment"
require_relative "config/sidekiq"
require_relative "lib/bot/telegram_client"
require_relative "lib/bot/command_handler"
require_relative "lib/bot/webhook_handler"

class App < Roda
  plugin :json
  plugin :json_parser, parser: ->(body) { Oj.load(body) }

  route do |r|
    r.get "health" do
      { status: "ok" }
    end

    r.post "webhook" do
      secret = r.env["HTTP_X_TELEGRAM_BOT_API_SECRET_TOKEN"]
      unless secret == Config["WEBHOOK_SECRET"]
        response.status = 403
        next { error: "forbidden" }
      end

      Bot::WebhookHandler.new(r.params).call

      { status: "ok" }
    end
  end
end
