# frozen_string_literal: true

require "roda"
require "oj"
require "logger"
require_relative "config/environment"
require_relative "config/sidekiq"
require_relative "lib/bot/telegram_client"
require_relative "lib/bot/whisper_client"
require_relative "lib/bot/stats"
require_relative "lib/bot/command_handler"
require_relative "lib/bot/update_handler"
require_relative "lib/jobs/transcribe_job"
require_relative "lib/jobs/improve_transcription_job"

class App < Roda
  plugin :json

  route do |r|
    r.get "health" do
      { status: "ok" }
    end
  end
end
