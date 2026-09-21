# frozen_string_literal: true

require "sidekiq"
require_relative "whisper_client"

module Bot
  # Turns a transcript into a summary worth reading. Short transcripts go to the
  # model in one piece; long ones are mapped to dense notes window by window and
  # then reduced, because a three-hour transcript stuffed into a single prompt
  # comes back shallow no matter which model gets it.
  class Summarizer
    SINGLE_PASS_CHARS = 24_000
    WINDOW_CHARS = 12_000

    SUMMARY_SYSTEM = <<~PROMPT
      You are summarizing a transcript of spoken material (a talk, video, podcast or voice note).

      Produce, in this order:
      - A section headed "TL;DR" — two or three sentences covering what this is and what it concludes.
      - Topic sections with a short header each, and bullets under them carrying the actual
        substance: arguments, reasoning, conclusions — not a table of contents.
      - A final section headed "Notable" — concrete numbers, names, claims, recommendations and
        references worth keeping. Omit this section if the material has none.

      Rules:
      - Write in the language of the transcript. Keep English technical terms as they appear.
      - Be specific. "Discusses pricing" is worthless; "argues usage pricing beats seats above 50 users" is not.
      - Never invent anything that is not in the transcript, and do not comment on the transcript itself.
      - Output only the summary, no preamble.

      Formatting (the output is rendered in a chat client, not a document):
      - Every section header is bold on its own line, written as **Header**. Never number the sections.
      - Every other line is a bullet starting with "- ", or a plain sentence.
      - No markdown headings (#), no tables, no code fences, no horizontal rules.
    PROMPT

    NOTES_SYSTEM = <<~PROMPT
      You are taking notes on one part of a longer transcript, for someone who will write the final
      summary from your notes alone and will never see this text.

      - Capture every distinct point, argument, conclusion, number, name and recommendation.
      - Dense bullets, no narration, no preamble, no "in this section".
      - Keep the language of the transcript.
      - Do not summarize away detail: this is source material, not a summary.
    PROMPT

    def initialize(whisper: WhisperClient.new, progress: nil, model: nil)
      @whisper = whisper
      @progress = progress
      @model = model || ENV["SUMMARY_MODEL"] || "gpt-4o"
    end

    def call(text, title: nil)
      text = text.to_s.strip
      return nil if text.empty?

      if text.length <= SINGLE_PASS_CHARS
        report("Summarizing...")
        summarize(text, title: title)
      else
        summarize(map_notes(text), title: title, from_notes: true)
      end
    end

    private

    def summarize(body, title:, from_notes: false)
      header = title ? "Title: #{title}\n\n" : ""
      label = from_notes ? "Notes taken from the full transcript, in order:" : "Transcript:"
      report("Writing the summary...") if from_notes
      @whisper.chat(SUMMARY_SYSTEM, "#{header}#{label}\n\n#{body}", model: @model, timeout: 180)
    end

    def map_notes(text)
      windows = split_windows(text)
      windows.each_with_index.map do |window, i|
        report("Summarizing part #{i + 1}/#{windows.length}...")
        @whisper.chat(NOTES_SYSTEM, window, timeout: 120)
      end.compact.join("\n\n")
    end

    # Windows break on paragraph boundaries so a point is rarely cut in half.
    # Paragraphs come free from the formatting pass, and a cached transcript has
    # no chunk list left to reuse.
    def split_windows(text)
      windows = []
      current = +""
      text.split(/\n{2,}/).each do |paragraph|
        if !current.empty? && current.length + paragraph.length > WINDOW_CHARS
          windows << current
          current = +""
        end
        current << "\n\n" unless current.empty?
        current << paragraph
      end
      windows << current unless current.empty?
      windows.flat_map { |w| w.length > WINDOW_CHARS * 2 ? w.scan(/.{1,#{WINDOW_CHARS}}/m) : [w] }
    end

    def report(message)
      @progress&.call(message)
    end
  end
end
