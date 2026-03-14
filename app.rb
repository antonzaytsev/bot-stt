# frozen_string_literal: true

require "roda"
require "oj"
require_relative "config/environment"
require_relative "config/sidekiq"

class App < Roda
  plugin :json
  plugin :json_parser, parser: ->(body) { Oj.load(body) }

  route do |r|
    r.get "health" do
      { status: "ok" }
    end
  end
end
