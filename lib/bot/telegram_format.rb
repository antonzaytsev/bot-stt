# frozen_string_literal: true

module Bot
  # The models answer in Markdown; Telegram does not render Markdown unless it
  # is asked to, and its own Markdown dialects reject unbalanced markers with a
  # 400. HTML is the forgiving parse mode, so summaries are converted to the
  # small tag set Telegram actually supports — and `plain` exists for the retry
  # when a conversion still comes out unparseable.
  module TelegramFormat
    BULLET = "•"
    NESTED_BULLET = "◦"
    # Code spans are lifted out before the other markers run, so a ** inside
    # `code` cannot turn into a tag Telegram refuses to nest.
    SENTINEL = "\u0000"

    class << self
      def html(text)
        in_code = false
        text.to_s.split("\n", -1).map { |line|
          if fence?(line)
            in_code = !in_code
            next in_code ? "<pre>" : "</pre>"
          end
          next escape(line) if in_code

          block(line)
        }.join("\n")
      end

      # Markdown markers stripped rather than converted: the fallback when a
      # conversion still comes back unparseable.
      def plain(text)
        in_code = false
        text.to_s.split("\n", -1).filter_map { |line|
          if fence?(line)
            in_code = !in_code
            next nil
          end
          next line if in_code

          strip_markers(bullets(heading_text(line)))
        }.join("\n")
      end

      def escape(text)
        text.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
      end

      private

      def fence?(line) = line.strip.start_with?("```")

      def block(line)
        return "" if horizontal_rule?(line)

        if (heading = line[/\A\s*\#{1,6}\s+(.+?)\s*\z/, 1])
          return "<b>#{inline(escape(heading))}</b>"
        end

        if (m = line.match(/\A(\s*)[-*+]\s+(.*)\z/))
          indent = m[1]
          marker = indent.length >= 2 ? NESTED_BULLET : BULLET
          return "#{indent}#{marker} #{inline(escape(m[2]))}"
        end

        inline(escape(line))
      end

      # Markers are matched on already-escaped text: escaping only touches
      # & < >, none of which carry meaning in Markdown.
      def inline(text)
        code = []
        out = text.gsub(/`([^`\n]+)`/) {
          code << Regexp.last_match(1)
          "#{SENTINEL}#{code.size - 1}#{SENTINEL}"
        }
        out = out.gsub(/\[([^\]\n]+)\]\((https?:[^\s)]+)\)/) {
          %(<a href="#{Regexp.last_match(2)}">#{Regexp.last_match(1)}</a>)
        }
        out = out.gsub(/\*\*([^*\n]+)\*\*/, '<b>\1</b>')
        out = out.gsub(/__([^_\n]+)__/, '<b>\1</b>')
        # \w is ASCII-only, which would let a marker glue itself to a Cyrillic word.
        out = out.gsub(/(?<![[:word:]*])\*(?!\s)([^*\n]+)(?<!\s)\*(?![[:word:]*])/, '<i>\1</i>')
        out = out.gsub(/(?<![[:word:]_])_(?!\s)([^_\n]+)(?<!\s)_(?![[:word:]_])/, '<i>\1</i>')
        out.gsub(/#{SENTINEL}(\d+)#{SENTINEL}/) { "<code>#{code[Regexp.last_match(1).to_i]}</code>" }
      end

      def horizontal_rule?(line)
        line.match?(/\A\s*([-*_])(\s*\1){2,}\s*\z/)
      end

      def heading_text(line)
        line[/\A\s*\#{1,6}\s+(.+?)\s*\z/, 1] || line
      end

      def bullets(line)
        line.sub(/\A(\s*)[-*+]\s+/) {
          indent = Regexp.last_match(1)
          "#{indent}#{indent.length >= 2 ? NESTED_BULLET : BULLET} "
        }
      end

      def strip_markers(line)
        line.gsub(/\*\*([^*\n]+)\*\*/, '\1').gsub(/__([^_\n]+)__/, '\1').gsub(/`([^`\n]+)`/, '\1')
      end
    end
  end
end
