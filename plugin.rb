# frozen_string_literal: true

# name: discourse-nexudus-auth
# about: Authenticates Discourse users against the Nexudus coworking REST API
# version: 0.1.0
# authors: Sadie
# url: https://github.com/your-org/discourse-nexudus_auth
# contact_emails: sadieforbes@proton.me

require_relative 'lib/nexudus_membership_provider'
require_relative 'lib/nexudus_authenticator'

auth_provider(
  title: 'with Nexudus',
  authenticator: NexudusAuthenticator.new
)
