# frozen_string_literal: true

require_relative "../test_helper"

class TestStats < Minitest::Test
  def setup
    Bot::Stats.instance_variable_set(:@processed, 0)
    Bot::Stats.instance_variable_set(:@failed, 0)
    Bot::Stats.instance_variable_set(:@boot_time, Time.now)
    Bot::Stats.instance_variable_set(:@last_reset_date, Date.today)
  end

  def test_record_success_increments_processed
    Bot::Stats.record_success!
    Bot::Stats.record_success!
    assert_equal 2, Bot::Stats.processed
    assert_equal 0, Bot::Stats.failed
  end

  def test_record_failure_increments_failed
    Bot::Stats.record_failure!
    assert_equal 0, Bot::Stats.processed
    assert_equal 1, Bot::Stats.failed
  end

  def test_uptime_returns_seconds
    Bot::Stats.instance_variable_set(:@boot_time, Time.now - 120)
    assert_in_delta 120, Bot::Stats.uptime, 1
  end

  def test_uptime_human_formats_seconds
    Bot::Stats.instance_variable_set(:@boot_time, Time.now - 5)
    assert_match(/\d+s/, Bot::Stats.uptime_human)
  end

  def test_uptime_human_formats_hours
    Bot::Stats.instance_variable_set(:@boot_time, Time.now - 3661)
    result = Bot::Stats.uptime_human
    assert_match(/1h/, result)
    assert_match(/1m/, result)
  end

  def test_uptime_human_formats_days
    Bot::Stats.instance_variable_set(:@boot_time, Time.now - 90_061)
    result = Bot::Stats.uptime_human
    assert_match(/1d/, result)
    assert_match(/1h/, result)
  end

  def test_resets_counters_on_new_day
    Bot::Stats.record_success!
    Bot::Stats.record_failure!
    assert_equal 1, Bot::Stats.processed
    assert_equal 1, Bot::Stats.failed

    Bot::Stats.instance_variable_set(:@last_reset_date, Date.today - 1)

    Bot::Stats.record_success!
    assert_equal 1, Bot::Stats.processed
    assert_equal 0, Bot::Stats.failed
  end
end
