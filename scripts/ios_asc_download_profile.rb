#!/usr/bin/env ruby
# frozen_string_literal: true

require "base64"
require "fileutils"
require "json"
require "net/http"
require "openssl"
require "optparse"
require "tempfile"
require "time"
require "uri"

Options = Struct.new(:profile_id, :profile_name, :output, keyword_init: true)

def fail_with(message)
  warn "ios-asc-download-profile: #{message}"
  exit 1
end

def parse_options
  options = Options.new
  OptionParser.new do |opts|
    opts.banner = "Usage: ios_asc_download_profile.rb (--profile-id ID | --profile-name NAME) --output PATH"
    opts.on("--profile-id ID") { |value| options.profile_id = value }
    opts.on("--profile-name NAME") { |value| options.profile_name = value }
    opts.on("--output PATH") { |value| options.output = value }
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
  now = Time.now.to_i
  header = { alg: "ES256", kid: require_env("APP_STORE_CONNECT_API_KEY_ID"), typ: "JWT" }
  payload = {
    iss: require_env("APP_STORE_CONNECT_API_ISSUER_ID"),
    iat: now,
    exp: now + 1_200,
    aud: "appstoreconnect-v1"
  }
  signing_input = [b64url(header.to_json), b64url(payload.to_json)].join(".")
  der = private_key.dsa_sign_asn1(OpenSSL::Digest::SHA256.digest(signing_input))
  raw = OpenSSL::ASN1.decode(der).value.map do |integer|
    bytes = integer.value.to_s(2)
    bytes = bytes[-32, 32] if bytes.bytesize > 32
    bytes.rjust(32, "\0")
  end.join
  "#{signing_input}.#{b64url(raw)}"
end

def api_get(uri_or_path, token, query = {})
  uri = if uri_or_path.start_with?("http")
          URI(uri_or_path)
        else
          URI::HTTPS.build(
            host: "api.appstoreconnect.apple.com",
            path: uri_or_path,
            query: query.empty? ? nil : URI.encode_www_form(query)
          )
        end
  request = Net::HTTP::Get.new(uri)
  request["Authorization"] = "Bearer #{token}"
  response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(request) }
  body = response.body.to_s.empty? ? {} : JSON.parse(response.body)
  return body if response.code.to_i.between?(200, 299)

  fail_with("GET #{uri.path} failed: HTTP #{response.code} #{JSON.dump(body)}")
end

def find_profile_by_name(name, token)
  profiles = []
  next_url = nil
  loop do
    body = if next_url
             api_get(next_url, token)
           else
             api_get("/v1/profiles", token, "limit" => "200")
           end
    profiles.concat(body.fetch("data", []))
    next_url = body.dig("links", "next")
    break if next_url.to_s.empty?
  end

  matches = profiles.select { |profile| profile.dig("attributes", "name") == name }
  active = matches.select { |profile| profile.dig("attributes", "profileState") == "ACTIVE" }
  candidates = active.empty? ? matches : active
  candidates.max_by do |profile|
    Time.parse(profile.dig("attributes", "expirationDate").to_s)
  rescue ArgumentError
    Time.at(0)
  end
end

def write_profile(path, encoded_content)
  directory = File.expand_path(File.dirname(path))
  FileUtils.mkdir_p(directory, mode: 0o700)
  Tempfile.create(["profile", ".mobileprovision"], directory) do |file|
    file.binmode
    file.write(Base64.decode64(encoded_content))
    file.flush
    file.fsync
    File.chmod(0o600, file.path)
    File.rename(file.path, path)
  end
end

options = parse_options
if options.profile_id.to_s.empty? == options.profile_name.to_s.empty?
  fail_with("provide exactly one of --profile-id or --profile-name")
end
fail_with("--output is required") if options.output.to_s.empty?

token = jwt
profile = if options.profile_id
            api_get("/v1/profiles/#{options.profile_id}", token).fetch("data")
          else
            find_profile_by_name(options.profile_name, token)
          end
fail_with("provisioning profile not found") unless profile

# 列表接口不保证返回 profileContent，因此统一读取详情，避免下载到空文件。
profile = api_get("/v1/profiles/#{profile.fetch("id")}", token).fetch("data")
attributes = profile.fetch("attributes")
fail_with("profile is not ACTIVE: #{attributes["profileState"]}") unless attributes["profileState"] == "ACTIVE"
expiration = Time.parse(attributes.fetch("expirationDate"))
fail_with("profile expired at #{expiration.utc.iso8601}") unless expiration > Time.now
content = attributes["profileContent"].to_s
fail_with("profileContent is empty") if content.empty?

output = File.expand_path(options.output)
write_profile(output, content)
puts "ASC_PROFILE_ID=#{profile.fetch("id")}"
puts "ASC_PROFILE_NAME=#{attributes.fetch("name")}"
puts "ASC_PROFILE_UUID=#{attributes.fetch("uuid")}"
puts "ASC_PROFILE_EXPIRES_AT=#{expiration.utc.iso8601}"
puts "ASC_PROFILE_OUTPUT=#{output}"
