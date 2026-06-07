# frozen_string_literal: true

# name: discourse-nexudus-auth
# about: Authenticates Discourse users against the Nexudus coworking REST API
# version: 0.1.0
# authors: Sadie Forbes
# url: https://github.com/sadie-f2/discourse-nexudus_auth
# contact_emails: sadieforbes@proton.me

NEXUDUS_AUTH_VERSION  = '0.1.0'
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
end
