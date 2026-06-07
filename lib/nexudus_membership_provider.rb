# frozen_string_literal: true
require 'net/http'
require 'json'

class NexudusMembershipProvider
  BASE_URL       = 'https://spaces.nexudus.com/api'
  PING_PATH      = '/helpers/ping'
  CONTRACTS_PATH = '/billing/coworkercontracts'
  TIMEOUT        = 10

  # Returns { email:, name:, nexudus_id: } on success, nil on bad credentials
  # or network error.
  def self.verify_and_fetch(email, password)
    return nil unless ping_ok?(email, password)
    fetch_member(email, password)
  rescue => e
    Rails.logger.error("[NexudusAuth] #{e.class}: #{e.message}")
    nil
  end

  # Diagnostic version: makes both API calls, captures every detail.
  # Returns a hash with :member (nil on failure) plus :ping_* and :contracts_* keys.
  def self.diagnose(email, password)
    out = {}

    begin
      r = get(PING_PATH, email, password)
      out[:ping_status] = r.code
      out[:ping_body]   = r.body.to_s[0, 300]
    rescue => e
      out[:ping_error] = "#{e.class}: #{e.message}"
    end

    begin
      r = get("#{CONTRACTS_PATH}?CoworkerContract_Active=true", email, password)
      out[:contracts_status] = r.code
      begin
        data = JSON.parse(r.body)
        out[:contracts_total_items]  = data['TotalItems'].to_s
        out[:contracts_record_count] = (data['Records'] || []).length.to_s
        out[:contracts_first_email]  = data.dig('Records', 0, 'CoworkerEmail').to_s
        out[:contracts_first_name]   = data.dig('Records', 0, 'CoworkerFullName').to_s
        rec = data['Records']&.first
        out[:member] = rec ? { email: rec['CoworkerEmail'] || email,
                                name:  rec['CoworkerFullName'] || email.split('@').first,
                                nexudus_id: rec['CoworkerId'].to_s } : nil
      rescue => e
        out[:contracts_parse_error] = "#{e.class}: #{e.message}"
        out[:contracts_raw_body]    = r.body.to_s[0, 300]
      end
    rescue => e
      out[:contracts_error] = "#{e.class}: #{e.message}"
    end

    out
  end

  def self.ping_ok?(email, password)
    get(PING_PATH, email, password).code == '200'
  end
  private_class_method :ping_ok?

  def self.fetch_member(email, password)
    resp = get("#{CONTRACTS_PATH}?CoworkerContract_Active=true", email, password)
    return nil unless resp.code == '200'
    records = JSON.parse(resp.body)['Records'] || []
    r = records.first
    return nil unless r
    {
      email:      r['CoworkerEmail'] || email,
      name:       r['CoworkerFullName'] || email.split('@').first,
      nexudus_id: r['CoworkerId'].to_s
    }
  end
  private_class_method :fetch_member

  def self.get(path, email, password)
    uri = URI("#{BASE_URL}#{path}")
    Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: TIMEOUT) do |http|
      req = Net::HTTP::Get.new(uri)
      req.basic_auth(email, password)
      req['Accept'] = 'application/json'
      http.request(req)
    end
  end
  private_class_method :get
end
