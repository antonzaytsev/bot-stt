# frozen_string_literal: true

require "logger"
require_relative "telegram_client"
require_relative "chat_gate"
require_relative "transcript_store"
require_relative "media_cache"
require_relative "../jobs/summarize_job"
require_relative "../jobs/transcribe_media_job"

module Bot
  # Inline button presses. Telegram caps callback data at 64 bytes, so every
  # payload is an action letter plus a token that resolves to a Redis record:
  #   s|<token> — summarize the transcript behind that token
  #   m|<token> — proceed with the long media behind that token
  class CallbackHandler
    def initialize(callback_query)
      @query = callback_query
      @logger = Logger.new($stdout)
      @logger.formatter = proc { |severity, time, _, msg| "#{time.utc.iso8601} #{severity} [callback] #{msg}\n" }
    end

    def call
      data = @query["data"].to_s
      chat_id = @query.dig("message", "chat", "id")
      chat_type = @query.dig("message", "chat", "type")
      user_id = @query.dig("from", "id")
      @logger.info("Callback data=#{data} chat=#{chat_id} from=#{user_id}")

      unless ChatGate.allowed?(chat_id: chat_id, chat_type: chat_type, user_id: user_id)
        @logger.info("Callback from disallowed chat, ignoring")
        return answer("Not allowed here.")
      end

      action, token = data.split("|", 2)
      case action
      when "s" then handle_summarize(token)
      when "m" then handle_proceed(token)
      else
        @logger.info("Unknown callback action: #{action}")
        answer
      end
    rescue => e
      @logger.error("Callback failed: #{e.class}: #{e.message}")
      answer("Something went wrong.")
    end

    private

    def handle_summarize(token)
      unless token && TranscriptStore.fetch(token)
        return answer("This transcript has expired — send the link or audio again.")
      end

      Jobs::SummarizeJob.perform_async(token)
      answer("Summarizing...")
    end

    # The request is consumed on the first tap: a second tap on a two-hour
    # podcast would otherwise download and transcribe it all over again, at full
    # price, for a week after the button appeared.
    def handle_proceed(token)
      request = token && MediaCache.take_request(token)
      return answer("This request has expired — send the link again.") unless request

      remove_keyboard
      Jobs::TranscribeMediaJob.perform_async(
        request["chat_id"], request["message_id"], request["url"], request["auto_summarize"], true
      )
      answer("Starting...")
    end

    def remove_keyboard
      chat_id = @query.dig("message", "chat", "id")
      message_id = @query.dig("message", "message_id")
      return unless chat_id && message_id

      TelegramClient.new.edit_message_reply_markup(chat_id: chat_id, message_id: message_id)
    rescue => e
      @logger.error("Failed to remove keyboard: #{e.message}")
    end

    # Telegram shows a spinner until the query is answered, so every path answers.
    def answer(text = nil)
      TelegramClient.new.answer_callback_query(callback_query_id: @query["id"], text: text)
    rescue => e
      @logger.error("Failed to answer callback: #{e.message}")
    end
  end
end
