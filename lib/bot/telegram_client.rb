# frozen_string_literal: true

require "httpx"
require "oj"

module Bot
  class TelegramClient
    BASE_URL = "https://api.telegram.org"

    def initialize(token: Config["TELEGRAM_BOT_TOKEN"])
      @token = token
      @http = HTTPX.with(timeout: { operation_timeout: 30 })
    end

    def set_webhook(url:, secret_token:)
      post("setWebhook", url: url, secret_token: secret_token, allowed_updates: ["message"])
    end

    def send_message(chat_id:, text:, parse_mode: nil)
      params = { chat_id: chat_id, text: text }
      params[:parse_mode] = parse_mode if parse_mode
      post("sendMessage", **params)
    end

    def reply_to_message(chat_id:, message_id:, text:, parse_mode: nil)
      params = { chat_id: chat_id, reply_to_message_id: message_id, text: text }
      params[:parse_mode] = parse_mode if parse_mode
      post("sendMessage", **params)
    end

    def get_file(file_id:)
      post("getFile", file_id: file_id)
    end

    def download_file(file_path:)
      url = "#{BASE_URL}/file/bot#{@token}/#{file_path}"
      response = @http.get(url)
      raise "Telegram download failed: #{response.status}" unless response.status == 200

      response.body.to_s
    end

    private

    def post(method, **params)
      url = "#{BASE_URL}/bot#{@token}/#{method}"
      response = @http.post(url, json: params)
      body = Oj.load(response.body.to_s)
      raise "Telegram API error: #{body["description"]}" unless body["ok"]

      body["result"]
    end
  end
end
