# frozen_string_literal: true

require "sidekiq"
require_relative "../bot/telegram_client"
require_relative "../bot/whisper_client"
require_relative "../bot/summarizer"
require_relative "../bot/transcript_delivery"
require_relative "../bot/transcript_store"
require_relative "../bot/media_cache"
require_relative "../bot/telegram_format"
require_relative "../bot/costs"

module Jobs
  # Summarizes a transcript that has already been delivered. Reached from the
  # Summarize button and from `/summarize <url>` once its transcript is out.
  class SummarizeJob
    include Sidekiq::Job

    sidekiq_options retry: 1

    # Telegram's ceiling is 4096; the converted HTML is what counts against it,
    # not the Markdown that went in.
    MAX_TEXT_CHARS = 3800
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
        deliver(cached, "Summary reused from cache — no new cost.")
        return
      end

      @status_msg_id = reply("Summarizing...")["message_id"]
      whisper = Bot::WhisperClient.new
      summary = Bot::Summarizer.new(whisper: whisper, progress: method(:update_status))
        .call(record["text"], title: @title)
      raise "Summarizer returned nothing" if summary.nil? || summary.empty?

      Bot::MediaCache.save_summary(media_key, summary) if media_key
      deliver(summary, cost_line(record["cost"], whisper.chat_spend))
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

    # The model answers in Markdown, which Telegram renders as literal asterisks
    # unless it is told otherwise. HTML is the parse mode that tolerates what
    # models actually produce; if it still comes back rejected, the message goes
    # out unformatted rather than not at all.
    def deliver(summary, footer)
      html = "#{Bot::TelegramFormat.html(summary)}\n\n<i>#{Bot::TelegramFormat.escape(footer)}</i>"
      plain = "#{Bot::TelegramFormat.plain(summary)}\n\n#{footer}"

      if html.length <= MAX_TEXT_CHARS
        send_text(html, plain)
        return
      end

      @telegram.send_document(
        chat_id: @chat_id,
        filename: summary_filename,
        data: Bot::TelegramFormat.plain(summary),
        caption: "Summary (#{summary.length} characters) · #{footer}",
        reply_to_message_id: @anchor_msg_id
      )
      update_status("Summary is #{summary.length} characters — sent as a file.")
    end

    def send_text(html, plain)
      post_summary(html, "HTML")
    rescue => e
      Sidekiq.logger.error("[summary] Formatted send rejected (#{e.message}), retrying unformatted")
      post_summary(plain, nil)
    end

    def post_summary(text, parse_mode)
      if @status_msg_id
        @telegram.edit_message_text(
          chat_id: @chat_id, message_id: @status_msg_id, text: text, parse_mode: parse_mode
        )
      else
        reply(text, parse_mode: parse_mode)
      end
    end

    def cost_line(transcript_cost, summary_cost)
      transcript_cost = transcript_cost.to_f
      summary = Bot::Costs.format(summary_cost)
      return "Cost: #{summary}" if transcript_cost.zero?

      total = Bot::Costs.format(transcript_cost + summary_cost)
      "Cost: #{total} (transcript #{Bot::Costs.format(transcript_cost)} + summary #{summary})"
    end

    def summary_filename
      "#{Bot::TranscriptDelivery.sanitize_name(@title)}-summary.txt"
    end

    def reply(text, parse_mode: nil)
      if @anchor_msg_id
        @telegram.reply_to_message(
          chat_id: @chat_id, message_id: @anchor_msg_id, text: text, parse_mode: parse_mode
        )
      else
        @telegram.send_message(chat_id: @chat_id, text: text, parse_mode: parse_mode)
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
