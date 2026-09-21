# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/bot/telegram_format"

class TestTelegramFormat < Minitest::Test
  def test_bold_becomes_a_tag
    assert_equal "<b>TL;DR</b>", Bot::TelegramFormat.html("**TL;DR**")
    assert_equal "<b>TL;DR</b>", Bot::TelegramFormat.html("__TL;DR__")
  end

  def test_headings_become_bold_lines
    assert_equal "<b>Notable</b>", Bot::TelegramFormat.html("## Notable")
  end

  def test_bullets_become_dots_and_keep_their_nesting
    assert_equal "• Первый пункт", Bot::TelegramFormat.html("- Первый пункт")
    assert_equal "  ◦ Вложенный", Bot::TelegramFormat.html("  - Вложенный")
  end

  def test_html_special_characters_are_escaped
    assert_equal "a &lt;b&gt; &amp; c", Bot::TelegramFormat.html("a <b> & c")
  end

  def test_inline_code_and_fences
    assert_equal "<code>n8n</code>", Bot::TelegramFormat.html("`n8n`")
    assert_equal "<pre>\nx &lt; 1\n</pre>", Bot::TelegramFormat.html("```\nx < 1\n```")
  end

  # A ** inside a code span must stay literal: Telegram will not nest tags there.
  def test_markers_inside_code_are_left_alone
    assert_equal "<code>a ** b</code>", Bot::TelegramFormat.html("`a ** b`")
  end

  def test_links
    assert_equal %(<a href="https://x.dev">docs</a>), Bot::TelegramFormat.html("[docs](https://x.dev)")
  end

  def test_italics_do_not_fire_inside_words
    assert_equal "snake_case_name", Bot::TelegramFormat.html("snake_case_name")
    assert_equal "<i>слово</i>", Bot::TelegramFormat.html("_слово_")
  end

  def test_unmatched_markers_are_left_as_text
    assert_equal "2 * 3 = 6", Bot::TelegramFormat.html("2 * 3 = 6")
    assert_equal "**unclosed", Bot::TelegramFormat.html("**unclosed")
  end

  def test_horizontal_rules_are_dropped
    assert_equal "", Bot::TelegramFormat.html("---")
  end

  def test_plain_strips_markers_instead_of_converting
    source = "## Notable\n- **500** компаний\n- `n8n` интеграция"
    assert_equal "Notable\n• 500 компаний\n• n8n интеграция", Bot::TelegramFormat.plain(source)
  end

  def test_a_whole_summary_round_trip
    source = "**TL;DR**\n- Платформа для AI-агентов\n\n**Notable**\n- 500 компаний"
    expected = "<b>TL;DR</b>\n• Платформа для AI-агентов\n\n<b>Notable</b>\n• 500 компаний"

    assert_equal expected, Bot::TelegramFormat.html(source)
  end
end
