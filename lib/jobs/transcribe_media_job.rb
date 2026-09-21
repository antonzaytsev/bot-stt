# frozen_string_literal: true

require "sidekiq"
require "fileutils"
require "tmpdir"
require "securerandom"
require_relative "../bot/telegram_client"
require_relative "../bot/whisper_client"
require_relative "../bot/audio_downloader"
require_relative "../bot/media_probe"
require_relative "../bot/media_cache"
require_relative "../bot/chunked_transcriber"
require_relative "../bot/transcript_delivery"
require_relative "../bot/stats"
require_relative "summarize_job"

module Jobs
  # The one pipeline for media behind a URL — YouTube links picked up from chat
  # and anything else reached through `/summarize <url>`. Video and podcasts are
  # the same path, not two paths that resemble each other.
  class TranscribeMediaJob
    include Sidekiq::Job

    sidekiq_options retry: 1

    CHUNK_SECONDS = 600
    WHISPER_COST_PER_MINUTE = 0.006
    DEFAULT_CONFIRM_MINUTES = 30
    # Whisper runs at roughly a tenth of real time, download and formatting on top.
    PROCESSING_SPEED = 8.0

    def self.make_downloader
      Bot::AudioDownloader.new
    end

    def self.make_probe(downloader)
      Bot::MediaProbe.new(downloader: downloader)
    end

    # A blank or non-numeric MEDIA_CONFIRM_MINUTES means "unset", not zero —
    # otherwise a stray empty value in .env would put a Proceed button under
    # every 45-second Short. An explicit 0 still means "confirm everything".
    def self.confirm_seconds
      minutes = Integer(ENV["MEDIA_CONFIRM_MINUTES"].to_s, exception: false) || DEFAULT_CONFIRM_MINUTES
      minutes * 60
    end

    sidekiq_retries_exhausted do |job, ex|
      chat_id, message_id, url = job["args"]
      Bot::TelegramClient.new.send_message(
        chat_id: Config["ADMIN_CHAT_ID"],
        text: "Media transcription permanently failed after retries\nChat: #{chat_id}\nMessage: #{message_id}\nURL: #{url}\nError: #{ex.class}: #{ex.message}"
      )
    rescue => e
      Sidekiq.logger.error("Failed to notify admin on retries exhausted: #{e.message}")
    end

    # `confirmed` is true when the user already tapped Proceed on a long item.
    def perform(chat_id, message_id, url, auto_summarize = false, confirmed = false)
      Sidekiq.logger.info("[media] START: chat=#{chat_id} msg=#{message_id} url=#{url} auto_summarize=#{auto_summarize}")

      @chat_id = chat_id
      @message_id = message_id
      @url = url
      @auto_summarize = auto_summarize
      @telegram = Bot::TelegramClient.new
      @whisper = Bot::WhisperClient.new
      @downloader = self.class.make_downloader

      @status_msg_id = reply("Fetching media info...")["message_id"]

      media = self.class.make_probe(@downloader).call(url)
      if (refusal = media.refusal)
        update_status(refusal)
        return
      end

      key = Bot::MediaCache.key_for(extractor: media.extractor, id: media.id, url: url)
      cached = Bot::MediaCache.fetch_transcript(key)
      if cached
        Sidekiq.logger.info("[media] Transcript cache hit: key=#{key}")
        deliver(cached["text"], media, key, cached: true)
        return
      end

      if needs_confirmation?(media, confirmed)
        ask_to_proceed(media)
        return
      end

      text = transcribe(media)
      Bot::MediaCache.save_transcript(key, text: text, title: media.title, duration: media.duration)
      deliver(text, media, key)

      Bot::Stats.record_success!
      Sidekiq.logger.info("[media] DONE: chat=#{chat_id} url=#{url} chars=#{text.length}")
    rescue => e
      Sidekiq.logger.error("[media] FAILED: chat=#{chat_id} url=#{url} error=#{e.class}: #{e.message}")
      Sidekiq.logger.error("[media] #{e.backtrace&.first(5)&.join("\n")}")
      Bot::Stats.record_failure!
      update_status(user_facing_error(e))
      notify_admin(e, chat_id, url)
      raise
    end

    private

    def transcribe(media)
      tmp_dir = Dir.mktmpdir("media")
      begin
        update_status("Downloading audio...")
        audio_path = @downloader.download(@url, output_dir: tmp_dir)

        update_status("Preparing audio...")
        chunks = @downloader.split_audio(audio_path, chunk_seconds: CHUNK_SECONDS, output_dir: tmp_dir)
        Sidekiq.logger.info("[media] Split into #{chunks.length} chunk(s)")

        Bot::ChunkedTranscriber.new(whisper: @whisper, progress: method(:update_status)).call(chunks)[:text]
      ensure
        FileUtils.remove_entry(tmp_dir) if File.directory?(tmp_dir)
      end
    end

    # Media transcripts always go out as a file — they are long, and a file is
    # what the user asked for.
    def deliver(text, media, key, cached: false)
      caption = [media.title, human_duration(media.duration), "#{text.length} characters"].compact.join(" · ")
      caption = "#{caption} (already transcribed)" if cached

      result = Bot::TranscriptDelivery.new(
        telegram: @telegram, chat_id: @chat_id, reply_to_message_id: @message_id
      ).call(
        text: text, source: "media", status_msg_id: @status_msg_id, force_file: true,
        base_name: media.title || "transcript", caption: caption,
        title: media.title, media_key: key, button: !@auto_summarize
      )

      update_status("Transcript ready.")
      SummarizeJob.perform_async(result[:token]) if @auto_summarize
    end

    def needs_confirmation?(media, confirmed)
      return false if confirmed
      return false if media.duration.nil?

      media.duration > self.class.confirm_seconds
    end

    def ask_to_proceed(media)
      token = SecureRandom.hex(6)
      Bot::MediaCache.save_request(token, {
        "chat_id" => @chat_id, "message_id" => @message_id, "url" => @url,
        "title" => media.title, "duration" => media.duration, "auto_summarize" => @auto_summarize
      })

      lines = [
        [media.title, human_duration(media.duration)].compact.join(" — "),
        "Transcribing costs about #{cost_estimate(media.duration)} and takes around #{human_duration(eta(media.duration))}."
      ]
      @telegram.edit_message_text(
        chat_id: @chat_id, message_id: @status_msg_id, text: lines.join("\n"),
        reply_markup: { inline_keyboard: [[{ text: "Proceed", callback_data: "m|#{token}" }]] }
      )
      Sidekiq.logger.info("[media] Awaiting confirmation: token=#{token} duration=#{media.duration}")
    end

    def cost_estimate(seconds)
      "$#{"%.2f" % ((seconds / 60.0) * WHISPER_COST_PER_MINUTE)}"
    end

    def eta(seconds)
      (seconds / PROCESSING_SPEED).round
    end

    def human_duration(seconds)
      return nil if seconds.nil?

      hours, rest = seconds.divmod(3600)
      minutes, secs = rest.divmod(60)
      return "#{hours}h #{minutes}m" if hours.positive?
      return "#{minutes}m" if minutes.positive?

      "#{secs}s"
    end

    def user_facing_error(error)
      case error.message
      when /yt-dlp|Command failed \(exit \d+\): yt-dlp/i
        "Could not fetch this media. The link may be private, region-locked, or unsupported."
      when /ffmpeg/i then "Could not convert this media's audio."
      else "Failed: #{error.message}"[0..4000]
      end
    end

    def reply(text)
      if @message_id
        @telegram.reply_to_message(chat_id: @chat_id, message_id: @message_id, text: text)
      else
        @telegram.send_message(chat_id: @chat_id, text: text)
      end
    end

    def update_status(text)
      return if @status_msg_id.nil?

      @telegram.edit_message_text(chat_id: @chat_id, message_id: @status_msg_id, text: text)
    rescue => e
      Sidekiq.logger.error("[media] Failed to update status: #{e.message}")
    end

    def notify_admin(error, chat_id, url)
      Bot::TelegramClient.new.send_message(
        chat_id: Config["ADMIN_CHAT_ID"],
        text: "Media transcription failed\nChat: #{chat_id}\nURL: #{url}\nError: #{error.class}: #{error.message}"
      )
    rescue => e
      Sidekiq.logger.error("[media] Failed to notify admin: #{e.message}")
    end
  end
end
