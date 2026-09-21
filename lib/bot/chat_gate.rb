# frozen_string_literal: true

module Bot
  # Who the bot listens to: the admin in a private chat, or anyone in the one
  # allowed group. Shared by message and callback handling so a button press is
  # authorised exactly like the message that produced the button.
  module ChatGate
    class << self
      def allowed?(chat_id:, chat_type:, user_id:)
        private_admin?(chat_type: chat_type, user_id: user_id) || allowed_group?(chat_id)
      end

      def private_admin?(chat_type:, user_id:)
        chat_type == "private" && admin?(user_id)
      end

      def allowed_group?(chat_id)
        allowed_id = ENV["ALLOWED_CHAT_ID"].to_s
        !allowed_id.empty? && chat_id.to_s == allowed_id
      end

      def admin?(user_id)
        user_id.to_s == Config["ADMIN_CHAT_ID"].to_s
      end
    end
  end
end
