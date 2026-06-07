# frozen_string_literal: true
require 'net/http'
require 'json'

class NexudusMembershipProvider
  BASE_URL       = 'https://spaces.nexudus.com/api'
  CONTRACTS_PATH = '/billing/coworkercontracts'
  TIMEOUT        = 10

  # Returns { email:, name:, nexudus_id: } on success, nil on bad/inactive credentials.
  # Uses coworkercontracts as both the credential check and member data source:
  # 401 = bad credentials, 200 + empty records = no active membership.
  def self.verify_and_fetch(email, password)
    fetch_member(email, password)
  rescue => e
    Rails.logger.error("[NexudusAuth] #{e.class}: #{e.message}")
    nil
  end

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
