# frozen_string_literal: true

# name: discourse-nexudus-auth
# about: Authenticates Discourse users against the Nexudus coworking REST API
# version: 0.1.5
# authors: Sadie Forbes
# url: https://github.com/sadie-f2/discourse-nexudus_auth
# contact_emails: sadieforbes@proton.me

NEXUDUS_AUTH_VERSION  = '0.1.5'
NEXUDUS_AUTH_GIT_HASH = `git -C #{File.dirname(__FILE__)} rev-parse --short HEAD 2>/dev/null`.strip.freeze

require_relative 'lib/nexudus_membership_provider'
require_relative 'lib/nexudus_authenticator'

enabled_site_setting :nexudus_auth_enabled

auth_provider(
  title: 'with Nexudus',
  authenticator: NexudusAuthenticator.new
)

after_initialize do
  Rails.logger.info("[NexudusAuth] loaded v#{NEXUDUS_AUTH_VERSION} (#{NEXUDUS_AUTH_GIT_HASH})")

  group_name = SiteSetting.nexudus_auth_group.to_s.strip
  Group.find_or_create_by(name: group_name) do |g|
    g.full_name        = "Makerspace Members"
    g.visibility_level = Group.visibility_levels[:public]
  end
  Rails.logger.info("[NexudusAuth] group '#{group_name}' ensured")
end
