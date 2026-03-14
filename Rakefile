# frozen_string_literal: true

require_relative "config/environment"

require "rake/testtask"

Rake::TestTask.new do |t|
  t.pattern = "test/**/test_*.rb"
  t.warning = false
end

task default: :test
