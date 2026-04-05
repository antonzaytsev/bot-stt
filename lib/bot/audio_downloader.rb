# frozen_string_literal: true

require "open3"
require "fileutils"
require "tmpdir"
require "logger"

module Bot
  class AudioDownloader
    YANDEX_MUSIC_RE = %r{\Ahttps?://music\.yandex\.(ru|com)/}i

    def initialize
      @logger = Logger.new($stdout)
      @logger.formatter = proc { |sev, time, _, msg| "#{time.utc.iso8601} #{sev} [downloader] #{msg}\n" }
    end

    def self.valid_url?(url)
      url.match?(YANDEX_MUSIC_RE)
    end

    def download(url, output_dir:)
      output_template = File.join(output_dir, "audio.%(ext)s")
      run_command(
        "yt-dlp", "--no-playlist", "-x", "--audio-format", "opus",
        "-o", output_template, url
      )
      Dir.glob(File.join(output_dir, "audio.*")).first or raise "yt-dlp produced no output file"
    end

    def split_audio(input_path, chunk_seconds: 600, output_dir:)
      pattern = File.join(output_dir, "chunk_%03d.ogg")
      run_command(
        "ffmpeg", "-i", input_path, "-f", "segment",
        "-segment_time", chunk_seconds.to_s,
        "-c:a", "libopus", "-b:a", "48k",
        "-vn", "-y", pattern
      )
      Dir.glob(File.join(output_dir, "chunk_*.ogg")).sort
    end

    private

    def run_command(*cmd)
      @logger.info("Running: #{cmd.join(' ')}")
      stdout_err, status = Open3.capture2e(*cmd)
      unless status.success?
        raise "Command failed (exit #{status.exitstatus}): #{cmd.first}\n#{stdout_err[0..500]}"
      end
      @logger.info("Command succeeded: #{cmd.first}")
      stdout_err
    end
  end
end
