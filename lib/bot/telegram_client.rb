# frozen_string_literal: true

require "net/http"
require "uri"
require "oj"
require "securerandom"

module Bot
  class TelegramClient
    BASE_URL = "https://api.telegram.org"

    def initialize(token: Config["TELEGRAM_BOT_TOKEN"])
      @token = token
    end

    def get_updates(offset: nil, timeout: 30)
      params = { timeout: timeout, allowed_updates: ["message", "message_reaction", "callback_query"] }
      params[:offset] = offset if offset
      post("getUpdates", **params)
    end

    def delete_webhook
      post("deleteWebhook")
    end

    def send_message(chat_id:, text:, parse_mode: nil, reply_markup: nil)
      params = { chat_id: chat_id, text: text }
      params[:parse_mode] = parse_mode if parse_mode
      params[:reply_markup] = reply_markup if reply_markup
      post("sendMessage", **params)
    end

    def reply_to_message(chat_id:, message_id:, text:, parse_mode: nil, reply_markup: nil)
      params = { chat_id: chat_id, reply_to_message_id: message_id, text: text }
      params[:parse_mode] = parse_mode if parse_mode
      params[:reply_markup] = reply_markup if reply_markup
      post("sendMessage", **params)
    end

    def edit_message_text(chat_id:, message_id:, text:, parse_mode: nil, reply_markup: nil)
      params = { chat_id: chat_id, message_id: message_id, text: text }
      params[:parse_mode] = parse_mode if parse_mode
      params[:reply_markup] = reply_markup if reply_markup
      post("editMessageText", **params)
    end

    # Passing no markup clears the buttons on a message.
    def edit_message_reply_markup(chat_id:, message_id:, reply_markup: nil)
      params = { chat_id: chat_id, message_id: message_id }
      params[:reply_markup] = reply_markup if reply_markup
      post("editMessageReplyMarkup", **params)
    end

    # Every callback query must be answered, otherwise the client shows a spinner
    # until it times out.
    def answer_callback_query(callback_query_id:, text: nil, show_alert: false)
      params = { callback_query_id: callback_query_id }
      params[:text] = text if text
      params[:show_alert] = true if show_alert
      post("answerCallbackQuery", **params)
    end

    def send_document(chat_id:, filename:, data:, caption: nil, reply_to_message_id: nil, reply_markup: nil)
      fields = { "chat_id" => chat_id.to_s }
      fields["caption"] = caption if caption
      fields["reply_to_message_id"] = reply_to_message_id.to_s if reply_to_message_id
      fields["reply_markup"] = Oj.dump(reply_markup) if reply_markup

      boundary = "----FormBoundary#{SecureRandom.hex(16)}"
      uri = URI("#{BASE_URL}/bot#{@token}/sendDocument")
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "multipart/form-data; boundary=#{boundary}"
      request.body = build_multipart_body(boundary, fields, filename, data)

      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 120) do |http|
        http.request(request)
      end

      body = Oj.load(response.body)
      raise "Telegram API error: #{body["description"]}" unless body["ok"]

      body["result"]
    end

    def set_my_commands(commands)
      post("setMyCommands", commands: commands)
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

    def build_multipart_body(boundary, fields, filename, data)
      body = +"".b
      fields.each do |name, value|
        body << "--#{boundary}\r\nContent-Disposition: form-data; name=\"#{name}\"\r\n\r\n#{value}\r\n".b
      end
      body << "--#{boundary}\r\nContent-Disposition: form-data; name=\"document\"; filename=\"#{filename}\"\r\n".b
      body << "Content-Type: application/octet-stream\r\n\r\n".b
      body << data.b
      body << "\r\n--#{boundary}--\r\n".b
      body
    end

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
