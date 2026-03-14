# frozen_string_literal: true

require "net/http"
require "uri"
require "oj"

module Bot
  class TelegramClient
    BASE_URL = "https://api.telegram.org"

    def initialize(token: Config["TELEGRAM_BOT_TOKEN"])
      @token = token
    end

    def get_updates(offset: nil, timeout: 30)
      params = { timeout: timeout, allowed_updates: ["message"] }
      params[:offset] = offset if offset
      post("getUpdates", **params)
    end

    def delete_webhook
      post("deleteWebhook")
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
      uri = URI("#{BASE_URL}/file/bot#{@token}/#{file_path}")
      response = Net::HTTP.get_response(uri)
      raise "Telegram download failed: #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      response.body
    end

    private

    def post(method, **params)
      uri = URI("#{BASE_URL}/bot#{@token}/#{method}")
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request.body = Oj.dump(params)

      read_timeout = params[:timeout] ? params[:timeout] + 5 : 30

      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 10, read_timeout: read_timeout) do |http|
        http.request(request)
      end

      body = Oj.load(response.body)
      raise "Telegram API error: #{body["description"]}" unless body["ok"]

      body["result"]
    end
  end
end
