#!/usr/bin/env ruby
# frozen_string_literal: true

require "base64"
require "json"
require "net/http"
require "openssl"
require "optparse"
require "uri"

Options = Struct.new(:bundle_id, :short_version, :build_version, keyword_init: true)

def fail_with(message)
  warn "ios-asc-build-number-preflight: #{message}"
  exit 1
end

def parse_options
  options = Options.new
  OptionParser.new do |opts|
    opts.banner = "Usage: ios_asc_build_number_preflight.rb --bundle-id BUNDLE --version VERSION --build BUILD"
    opts.on("--bundle-id ID") { |value| options.bundle_id = value }
    opts.on("--version VERSION") { |value| options.short_version = value }
    opts.on("--build BUILD") { |value| options.build_version = value }
  end.parse!
  options
end

def require_env(name)
  value = ENV[name].to_s
  fail_with("#{name} is required") if value.empty?
  value
end

def b64url(data)
  Base64.urlsafe_encode64(data).delete("=")
end

def private_key
  path = require_env("APP_STORE_CONNECT_API_KEY_PATH")
  fail_with("APP_STORE_CONNECT_API_KEY_PATH not found: #{path}") unless File.file?(path)
  OpenSSL::PKey.read(File.read(path))
end

def jwt
  key_id = require_env("APP_STORE_CONNECT_API_KEY_ID")
  issuer_id = require_env("APP_STORE_CONNECT_API_ISSUER_ID")
  now = Time.now.to_i
  header = { alg: "ES256", kid: key_id, typ: "JWT" }
  payload = { iss: issuer_id, iat: now, exp: now + 1_200, aud: "appstoreconnect-v1" }
  signing_input = [b64url(header.to_json), b64url(payload.to_json)].join(".")

  # App Store Connect 的 ES256 JWT 需要 64 字节 r+s 签名，不能直接使用 OpenSSL 的 DER 结果。
  der = private_key.dsa_sign_asn1(OpenSSL::Digest::SHA256.digest(signing_input))
  raw = OpenSSL::ASN1.decode(der).value.map do |integer|
    bytes = integer.value.to_s(2)
    bytes = bytes[-32, 32] if bytes.bytesize > 32
    bytes.rjust(32, "\0")
  end.join
  "#{signing_input}.#{b64url(raw)}"
end

def api_get(path, query, token)
  uri = URI::HTTPS.build(
    host: "api.appstoreconnect.apple.com",
    path: path,
    query: URI.encode_www_form(query)
  )
  request = Net::HTTP::Get.new(uri)
  request["Authorization"] = "Bearer #{token}"
  response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(request) }
  body = response.body.to_s.empty? ? {} : JSON.parse(response.body)
  return body if response.code.to_i.between?(200, 299)

  fail_with("GET #{path} failed: HTTP #{response.code} #{JSON.dump(body)}")
end

def compare(left, right)
  left_parts = left.split(".").map(&:to_i)
  right_parts = right.split(".").map(&:to_i)
  [left_parts.length, right_parts.length].max.times do |index|
    result = (left_parts[index] || 0) <=> (right_parts[index] || 0)
    return result unless result.zero?
  end
  0
end

def next_build(value)
  parts = value.split(".").map(&:to_i)
  parts[-1] += 1
  parts.join(".")
end

options = parse_options
fail_with("--bundle-id is required") if options.bundle_id.to_s.empty?
fail_with("--version is required") if options.short_version.to_s.empty?
fail_with("--build is required") if options.build_version.to_s.empty?
fail_with("build must be numeric") unless options.build_version.match?(/\A\d+(?:\.\d+){0,2}\z/)

token = jwt
app = api_get("/v1/apps", { "filter[bundleId]" => options.bundle_id, "limit" => "1" }, token)
app_id = app.dig("data", 0, "id")
fail_with("App Store Connect app not found: #{options.bundle_id}") if app_id.to_s.empty?

builds = api_get(
  "/v1/builds",
  {
    "filter[app]" => app_id,
    "filter[preReleaseVersion.version]" => options.short_version,
    "limit" => "200"
  },
  token
).fetch("data", [])

# 常驻 runner 可能仍是 Ruby 2.6，这里避免使用 filter_map。
numeric_builds = builds.each_with_object([]) do |build, result|
  value = build.dig("attributes", "version").to_s
  result << value if value.match?(/\A\d+(?:\.\d+){0,2}\z/)
end
latest = numeric_builds.max { |left, right| compare(left, right) }
suggested = latest && compare(options.build_version, latest) <= 0 ? next_build(latest) : options.build_version

puts "ASC_CURRENT_BUILD=#{options.build_version}"
puts "ASC_SUGGESTED_BUILD_NUMBER=#{suggested}"
puts "ASC_REMOTE_LATEST_BUILD=#{latest || ""}"
