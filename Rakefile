# frozen_string_literal: true

require_relative "config/environment"

require "rake/testtask"

Rake::TestTask.new do |t|
  t.pattern = "test/**/test_*.rb"
  t.warning = false
end

task default: :test

namespace :bot do
  desc "Register bot command menu with Telegram"
  task :set_commands do
    require_relative "lib/bot/telegram_client"
    require_relative "lib/bot/command_handler"
    Bot::TelegramClient.new.set_my_commands(Bot::CommandHandler::MENU)
    puts "Bot command menu registered"
  end
end
