# frozen_string_literal: true

require "sidekiq"

module Jobs
  class TranscribeJob
    include Sidekiq::Job

    sidekiq_options retry: 2

    def perform(chat_id, message_id, file_id)
      # Implemented in Phase 3
    end
  end
end
