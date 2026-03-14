# frozen_string_literal: true

port ENV.fetch("PORT", 3000)
bind "tcp://0.0.0.0:#{ENV.fetch("PORT", 3000)}"
environment ENV.fetch("RACK_ENV", "development")
workers 0
threads 1, 5
