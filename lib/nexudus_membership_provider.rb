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
