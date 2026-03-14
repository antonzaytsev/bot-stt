# frozen_string_literal: true

require "dotenv/load" if ENV["RACK_ENV"] != "production"
require "oj"

Oj.default_options = { mode: :compat, symbol_keys: false }

module Config
  REQUIRED_VARS = %w[
    TELEGRAM_BOT_TOKEN
    OPENAI_API_KEY
    ADMIN_CHAT_ID
    REDIS_URL
    PORT
  ].freeze

  def self.load!
    missing = REQUIRED_VARS.select { |var| ENV[var].to_s.empty? }
    unless missing.empty?
      abort "Missing required environment variables: #{missing.join(', ')}"
    end
  end

  def self.[](key)
    ENV.fetch(key)
  end
end

Config.load! unless ENV["RACK_ENV"] == "test"
