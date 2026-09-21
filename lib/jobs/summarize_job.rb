# frozen_string_literal: true

require "sidekiq"
require_relative "../bot/telegram_client"
require_relative "../bot/whisper_client"
require_relative "../bot/summarizer"
require_relative "../bot/transcript_delivery"
require_relative "../bot/transcript_store"
require_relative "../bot/media_cache"

module Jobs
  # Summarizes a transcript that has already been delivered. Reached from the
  # Summarize button and from `/summarize <url>` once its transcript is out.
  class SummarizeJob
    include Sidekiq::Job

    sidekiq_options retry: 1

    MAX_TEXT_CHARS = 3500
    LOCK_TTL = 3600

    def perform(token)
      record = Bot::TranscriptStore.fetch(token)
      unless record
        Sidekiq.logger.info("[summary] Transcript expired: token=#{token}")
        return
      end

      @telegram = Bot::TelegramClient.new
      @chat_id = record["chat_id"]
      @anchor_msg_id = record["anchor_msg_id"]
      @title = record["title"]
      media_key = record["media_key"]

      return unless claim(token)

      remove_button(record)

      cached = media_key && Bot::MediaCache.fetch_summary(media_key)
      if cached
        Sidekiq.logger.info("[summary] Cache hit: key=#{media_key}")
        deliver(cached)
        return
      end

      @status_msg_id = reply("Summarizing...")["message_id"]
      summary = Bot::Summarizer.new(progress: method(:update_status)).call(record["text"], title: @title)
      raise "Summarizer returned nothing" if summary.nil? || summary.empty?

      Bot::MediaCache.save_summary(media_key, summary) if media_key
      deliver(summary)
      Sidekiq.logger.info("[summary] DONE: chat=#{@chat_id} token=#{token} chars=#{summary.length}")
    rescue => e
      Sidekiq.logger.error("[summary] FAILED: token=#{token} error=#{e.class}: #{e.message}")
      release(token)
      update_status("Summary failed: #{e.message}"[0..4000])
      raise
    end

    private

    # One summary per transcript: a double tap arrives as two jobs, and the
    # second must not pay for the same tokens again.
    def claim(token)
      Sidekiq.redis { |c| c.call("SET", "summarizing:#{token}", "1", "NX", "EX", LOCK_TTL) } == "OK"
    end

    def release(token)
      Sidekiq.redis { |c| c.call("DEL", "summarizing:#{token}") }
    rescue => e
      Sidekiq.logger.error("[summary] Failed to release lock: #{e.message}")
    end

    def remove_button(record)
      return unless record["button"] && @anchor_msg_id

      @telegram.edit_message_reply_markup(chat_id: @chat_id, message_id: @anchor_msg_id)
    rescue => e
      Sidekiq.logger.error("[summary] Failed to remove button: #{e.message}")
    end

    def deliver(summary)
      if summary.length <= MAX_TEXT_CHARS
        if @status_msg_id
          @telegram.edit_message_text(chat_id: @chat_id, message_id: @status_msg_id, text: summary)
        else
          reply(summary)
        end
        return
      end

      @telegram.send_document(
        chat_id: @chat_id,
        filename: summary_filename,
        data: summary,
        caption: "Summary (#{summary.length} characters)",
        reply_to_message_id: @anchor_msg_id
      )
      update_status("Summary is #{summary.length} characters — sent as a file.")
    end

    def summary_filename
      "#{Bot::TranscriptDelivery.sanitize_name(@title)}-summary.txt"
    end

    def reply(text)
      if @anchor_msg_id
        @telegram.reply_to_message(chat_id: @chat_id, message_id: @anchor_msg_id, text: text)
      else
        @telegram.send_message(chat_id: @chat_id, text: text)
      end
    end

    def update_status(text)
      return if @status_msg_id.nil?

      @telegram.edit_message_text(chat_id: @chat_id, message_id: @status_msg_id, text: text)
    rescue => e
      Sidekiq.logger.error("[summary] Failed to update status: #{e.message}")
    end
  end
end
