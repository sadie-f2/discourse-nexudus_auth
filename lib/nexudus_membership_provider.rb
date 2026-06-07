# frozen_string_literal: true
require 'open3'
require 'base64'
require 'json'
require 'uri'

class NexudusMembershipProvider
  BASE_URL       = ENV.fetch('NEXUDUS_BASE_URL', 'https://spaces.nexudus.com/api').freeze
  CONTRACTS_PATH = '/billing/coworkercontracts'
  TIMEOUT        = 10

  # Returns { email:, name:, nexudus_id: } if email matches an active member, nil otherwise.
  def self.verify_and_fetch(email)
    fetch_member(email)
  rescue => e
    Rails.logger.error("[NexudusAuth] #{e.class}: #{e.message}")
    nil
  end

  # Makes the same API call as verify_and_fetch but returns a diagnostics hash
  # (including :member on success) instead of raising or returning bare nil.
  def self.diagnose(email)
    out = {}
    token = ENV['NEXUDUS_BOOKING_TOKEN'].to_s.strip
    out[:auth_type]        = token.empty? ? 'basic' : 'bearer'
    out[:auth_configured]  = (!token.empty? || !ENV['NEXUDUS_EMAIL'].to_s.empty?) ? 'yes' : 'NO — missing env vars'
    out[:base_url]         = BASE_URL

    begin
      r = api_get(CONTRACTS_PATH, 'CoworkerContract_Active' => 'true', 'size' => '1000')
      out[:contracts_status] = r.code
      begin
        data    = JSON.parse(r.body)
        records = data['Records'] || []
        out[:contracts_total_items]  = data['TotalItems'].to_s
        out[:contracts_record_count] = records.length.to_s
        match = records.find { |rec| rec['CoworkerEmail'].to_s.downcase == email.downcase }
        out[:email_match_found] = match ? 'YES' : 'no'
        out[:member] = match ? {
          email:      match['CoworkerEmail'],
          name:       match['CoworkerFullName'] || email.split('@').first,
          nexudus_id: match['CoworkerId'].to_s
        } : nil
      rescue => e
        out[:contracts_parse_error] = "#{e.class}: #{e.message}"
        out[:contracts_raw_body]    = r.body.to_s[0, 300]
      end
    rescue => e
      out[:contracts_error] = "#{e.class}: #{e.message}"
    end

    out
  end

  private

  def self.fetch_member(email)
    r = api_get(CONTRACTS_PATH, 'CoworkerContract_Active' => 'true', 'size' => '1000')
    return nil unless r.code == '200'
    records = JSON.parse(r.body)['Records'] || []
    match = records.find { |rec| rec['CoworkerEmail'].to_s.downcase == email.downcase }
    return nil unless match
    {
      email:      match['CoworkerEmail'],
      name:       match['CoworkerFullName'] || email.split('@').first,
      nexudus_id: match['CoworkerId'].to_s
    }
  end
  private_class_method :fetch_member

  # Shell out to curl — Ruby's TLS fingerprint is blocked by CloudFront WAF,
  # curl's libssl is not.
  def self.api_get(path, params = nil)
    uri = URI.parse("#{BASE_URL}/#{path.to_s.delete_prefix('/')}")
    uri.query = URI.encode_www_form(params) if params && !params.empty?

    stdout, _stderr, _status = Open3.capture3(
      'curl', '-s',
      '--max-time', TIMEOUT.to_s,
      '-w', "\n%{http_code}",
      *curl_auth_args,
      '-H', 'Accept: application/json',
      uri.to_s
    )

    # curl -w appends the status code on a new line after the body
    *body_lines, code = stdout.lines
    Response.new(code.to_s.strip, body_lines.join)
  end
  private_class_method :api_get

  def self.curl_auth_args
    token = ENV['NEXUDUS_BOOKING_TOKEN'].to_s.strip
    if token.empty?
      ['-u', "#{ENV['NEXUDUS_EMAIL']}:#{ENV['NEXUDUS_PASSWORD']}"]
    else
      ['-H', "Authorization: Bearer #{token}"]
    end
  end
  private_class_method :curl_auth_args

  Response = Struct.new(:code, :body)
end
