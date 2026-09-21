# frozen_string_literal: true

require_relative "audio_downloader"

module Bot
  # Identity and size of a media URL, resolved before anything is downloaded:
  # the cache lookup, the refusals and the long-media confirmation all need to
  # happen while the job is still free.
  class MediaProbe
    Result = Struct.new(:id, :extractor, :title, :duration, :live, :playlist, keyword_init: true) do
      def live? = live
      def playlist? = playlist
      def refusal
        return "Live streams are not supported — try again once the stream has ended." if live?
        return "Playlists are not supported — send a link to a single video or episode." if playlist?

        nil
      end
    end

    def initialize(downloader: AudioDownloader.new)
      @downloader = downloader
    end

    def call(url)
      info = @downloader.probe(url) || {}

      Result.new(
        id: info["id"],
        extractor: info["extractor"] || info["extractor_key"],
        title: info["title"],
        duration: info["duration"]&.to_i,
        live: %w[is_live is_upcoming].include?(info["live_status"]) || info["is_live"] == true,
        playlist: info["_type"] == "playlist" || info["_type"] == "multi_video"
      )
    end
  end
end
