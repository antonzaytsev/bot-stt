# frozen_string_literal: true

require "sidekiq"
require_relative "transcript_store"

module Bot
  # Hands a finished transcript to the user and leaves behind everything a later
  # "Summarize" tap needs. Short transcripts land in the chat, long ones (and
  # anything from a media URL) come back as a .txt file.
  class TranscriptDelivery
    MAX_TEXT_CHARS = 3500
    SUMMARY_BUTTON_TEXT = "Summarize"
    MAX_FILENAME_CHARS = 80
    # Below this a chat transcript gets no button — a short voice note is already
    # shorter than any summary of it would be. Media always gets one: the user
    # asked for that media on purpose.
    MIN_SUMMARY_CHARS = 1000

    def initialize(telegram:, chat_id:, reply_to_message_id:)
      @telegram = telegram
      @chat_id = chat_id
      @reply_to_message_id = reply_to_message_id
    end

    # Returns { token:, anchor_msg_id: } — the anchor is the message carrying the
    # transcript, which is also where the summary gets attached later.
    def call(text:, source:, status_msg_id: nil, force_file: false, base_name: nil,
             caption: nil, title: nil, media_key: nil, button: true, cost: nil)
      token = TranscriptStore.new_token
      button &&= force_file || text.length >= MIN_SUMMARY_CHARS
      markup = button ? summary_markup(token) : nil
      as_file = force_file || text.length > MAX_TEXT_CHARS

      anchor_msg_id =
        if as_file
          deliver_as_file(text, base_name: base_name, caption: caption, markup: markup, status_msg_id: status_msg_id)
        else
          deliver_as_text(text, markup: markup, status_msg_id: status_msg_id)
        end

      TranscriptStore.save(
        token: token, chat_id: @chat_id, anchor_msg_id: anchor_msg_id, text: text,
        source: source, title: title, media_key: media_key, button: button, cost: cost
      )

      { token: token, anchor_msg_id: anchor_msg_id, as_file: as_file, button: button }
    end

    # The keyboard a delivered transcript carries, so a later edit of that
    # message can put it back — Telegram drops the keyboard on any edit that
    # omits it.
    def self.summary_markup(token)
      { inline_keyboard: [[{ text: SUMMARY_BUTTON_TEXT, callback_data: "s|#{token}" }]] }
    end

    private

    def deliver_as_text(text, markup:, status_msg_id:)
      if status_msg_id
        @telegram.edit_message_text(chat_id: @chat_id, message_id: status_msg_id, text: text, reply_markup: markup)
        status_msg_id
      else
        sent = @telegram.reply_to_message(
          chat_id: @chat_id, message_id: @reply_to_message_id, text: text, reply_markup: markup
        )
        sent["message_id"]
      end
    end

    def deliver_as_file(text, base_name:, caption:, markup:, status_msg_id:)
      Sidekiq.logger.info("[delivery] Sending transcript as file (#{text.length} chars)")
      sent = @telegram.send_document(
        chat_id: @chat_id,
        filename: filename_for(base_name),
        data: text,
        caption: caption || "Transcript (#{text.length} characters)",
        reply_to_message_id: @reply_to_message_id,
        reply_markup: markup
      )
      update_status("Transcript is #{text.length} characters — sent as a file.", status_msg_id)
      sent["message_id"]
    end

    def summary_markup(token)
      self.class.summary_markup(token)
    end

    # Media titles arrive as free text, so anything that could confuse a file name
    # is collapsed to spaces before the .txt suffix goes on. [[:word:]] rather
    # than \w: most titles this bot sees are not ASCII.
    def filename_for(base_name)
      "#{self.class.sanitize_name(base_name)}.txt"
    end

    def self.sanitize_name(name)
      base = File.basename(name.to_s, ".*").gsub(/[^[:word:] .()-]+/, " ").squeeze(" ").strip
      base = "transcript" if base.empty?
      base[0, MAX_FILENAME_CHARS]
    end

    def update_status(text, status_msg_id)
      return unless status_msg_id

      @telegram.edit_message_text(chat_id: @chat_id, message_id: status_msg_id, text: text)
    rescue => e
      Sidekiq.logger.error("[delivery] Failed to update status: #{e.message}")
    end
  end
end
