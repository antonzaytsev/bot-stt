# frozen_string_literal: true

require "open3"
require "fileutils"
require "tmpdir"
require "logger"
require "oj"

module Bot
  class AudioDownloader
    URL_RE = %r{\Ahttps?://}i

    def initialize
      @logger = Logger.new($stdout)
      @logger.formatter = proc { |sev, time, _, msg| "#{time.utc.iso8601} #{sev} [downloader] #{msg}\n" }
    end

    def self.valid_url?(url)
      url.match?(URL_RE)
    end

    # Metadata only — no media is fetched, so this is cheap enough to run before
    # deciding whether the job is worth starting at all.
    def probe(url)
      output = run_command(
        "yt-dlp", "-J", "--no-warnings", "--no-playlist", "--flat-playlist", "--skip-download", url
      )
      # Warnings share the stream with the payload; the JSON is the one line that is a JSON object.
      json = output.lines.reverse.find { |line| line.start_with?("{") }
      raise "yt-dlp returned no metadata" unless json

      Oj.load(json)
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
