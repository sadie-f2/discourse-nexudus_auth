# frozen_string_literal: true
require 'omniauth'

module OmniAuth
  module Strategies
    class Nexudus
      include OmniAuth::Strategy
      option :name, 'nexudus'

      def request_phase
        form = OmniAuth::Form.new(title: 'Log in with Nexudus', url: callback_path)
        form.text_field('Email', 'email')
        form.password_field('Password', 'password')
        form.to_response
      end

      def callback_phase
        email    = request.params['email'].to_s.strip.downcase
        password = request.params['password'].to_s

        member = ::NexudusMembershipProvider.verify_and_fetch(email, password)
        return fail!(:invalid_credentials) if member.nil?

        env['omniauth.auth'] = OmniAuth::AuthHash.new(
          provider: name,
          uid:      member[:email],
          info: {
            email: member[:email],
            name:  member[:name]
          },
          extra: { nexudus_id: member[:nexudus_id] }
        )
        call_app!
      end
    end
  end
end

class NexudusAuthenticator < Auth::Authenticator
  GROUP_NAME = 'nexudus-members'

  def name
    'nexudus'
  end

  def enabled?
    SiteSetting.nexudus_auth_enabled
  end

  def can_connect_existing_user?
    true
  end

  def register_middleware(omniauth)
    omniauth.provider :nexudus
  end

  def after_authenticate(auth_token, existing_account: nil)
    result            = Auth::Result.new
    info              = auth_token.info
    result.email      = info[:email]
    result.name       = info[:name]
    result.email_valid = true

    account      = UserAssociatedAccount.find_by(provider_name: name,
                                                  provider_uid:  auth_token.uid)
    result.user  = account&.user
    result
  end

  def after_create_account(user, auth)
    super
    add_to_nexudus_group(user)
  end

  def after_connect_existing_user(user, auth)
    super
    add_to_nexudus_group(user)
  end

  private

  def add_to_nexudus_group(user)
    group = Group.find_by(name: GROUP_NAME)
    unless group
      Rails.logger.warn("[NexudusAuth] Group '#{GROUP_NAME}' not found — create it in Discourse admin")
      return
    end
    group.add(user) unless group.users.include?(user)
  end
end
