# frozen_string_literal: true

require_relative "../../config/environment"
require_relative "../../config/sidekiq"
require_relative "command_handler"
require_relative "poller"

Bot::Poller.new.run
