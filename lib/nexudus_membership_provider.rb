# frozen_string_literal: true
require 'net/http'
require 'base64'
require 'json'

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

  def self.auth_header
    token = ENV['NEXUDUS_BOOKING_TOKEN'].to_s.strip
    unless token.empty?
      return { 'Authorization' => "Bearer #{token}" }
    end
    encoded = Base64.strict_encode64("#{ENV['NEXUDUS_EMAIL']}:#{ENV['NEXUDUS_PASSWORD']}")
    { 'Authorization' => "Basic #{encoded}" }
  end
  private_class_method :auth_header

  def self.api_get(path, params = nil)
    uri = URI.parse("#{BASE_URL}/#{path.to_s.delete_prefix('/')}")
    uri.query = URI.encode_www_form(params) if params && !params.empty?

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl      = true
    http.read_timeout = TIMEOUT

    req = Net::HTTP::Get.new(uri.request_uri)
    auth_header.each { |k, v| req[k] = v }
    req['Accept'] = 'application/json'

    http.request(req)
  end
  private_class_method :api_get
end
