# frozen_string_literal: true
require 'open3'
require 'json'
require 'set'
require 'uri'

class NexudusMembershipProvider
  BASE_URL       = ENV.fetch('NEXUDUS_BASE_URL', 'https://spaces.nexudus.com/api').freeze
  CONTRACTS_PATH = '/billing/coworkercontracts'
  PAGE_SIZE      = 100
  TIMEOUT        = 15
  CACHE_TTL      = 300  # seconds — refetch on miss only if cache is this old

  @@cache     = nil
  @@loaded_at = nil

  # Warm the cache at startup so the first login doesn't pay the fetch cost.
  def self.preload!
    load_members! if @@cache.nil?
  end

  # Returns { email:, name:, nexudus_id: } or nil.
  # On a miss, refetches once if the cache is stale — but not if we just loaded it.
  def self.find_member(email)
    load_members! if @@cache.nil?
    match = lookup(email)
    if !match && cache_stale?
      load_members!
      match = lookup(email)
    end
    match
  end

  # Same lookup as find_member but returns a diagnostics hash (including
  # :member on success) for the diagnostic page.
  def self.diagnose(email)
    out = {}
    token = ENV['NEXUDUS_BOOKING_TOKEN'].to_s.strip
    out[:auth_type]       = token.empty? ? 'basic' : 'bearer'
    out[:auth_configured] = (!token.empty? || !ENV['NEXUDUS_EMAIL'].to_s.empty?) ? 'yes' : 'NO — missing env vars'
    out[:base_url]        = BASE_URL
    out[:cache_size_before] = @@cache ? @@cache.length.to_s : 'empty'

    member = find_member(email)

    out[:cache_size]        = @@cache.length.to_s
    out[:email_match_found] = member ? 'YES' : 'no'
    out[:member]            = member
    out
  end

  private

  def self.lookup(email)
    (@@cache || []).find { |m| m[:email].downcase == email.downcase }
  end
  private_class_method :lookup

  def self.cache_stale?
    @@loaded_at.nil? || (Time.now - @@loaded_at) > CACHE_TTL
  end
  private_class_method :cache_stale?

  def self.load_members!
    records = []
    page    = 1
    loop do
      r = api_get(CONTRACTS_PATH,
                  'CoworkerContract_Active' => 'true',
                  'size'                    => PAGE_SIZE.to_s,
                  'page'                    => page.to_s)
      break unless r.code == '200'
      data = JSON.parse(r.body)
      records.concat(data['Records'] || [])
      break unless data['HasNextPage']
      page += 1
    end

    seen    = Set.new
    members = []
    records.each do |rec|
      id = rec['CoworkerId']
      next if seen.include?(id)
      seen.add(id)
      members << {
        email:      rec['CoworkerEmail'].to_s,
        name:       rec['CoworkerFullName'].to_s,
        nexudus_id: id.to_s
      }
    end

    @@cache     = members
    @@loaded_at = Time.now
    Rails.logger.info("[NexudusAuth] member cache loaded: #{@@cache.length} members (#{page} page(s))")
  rescue => e
    Rails.logger.error("[NexudusAuth] load_members! failed: #{e.class}: #{e.message}")
    @@cache ||= []
  end
  private_class_method :load_members!

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
