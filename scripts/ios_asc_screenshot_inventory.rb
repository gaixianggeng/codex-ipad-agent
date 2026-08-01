#!/usr/bin/env ruby
# frozen_string_literal: true

require "base64"
require "json"
require "net/http"
require "openssl"
require "optparse"
require "time"
require "uri"

Options = Struct.new(:bundle_id, :output, keyword_init: true)

def fail_with(message)
  warn "ios-asc-screenshot-inventory: #{message}"
  exit 1
end

def parse_options
  options = Options.new
  OptionParser.new do |opts|
    opts.banner = "Usage: ios_asc_screenshot_inventory.rb --bundle-id ID --output PATH"
    opts.on("--bundle-id ID") { |value| options.bundle_id = value }
    opts.on("--output PATH") { |value| options.output = value }
  end.parse!
  fail_with("--bundle-id is required") if options.bundle_id.to_s.empty?
  fail_with("--output is required") if options.output.to_s.empty?
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
  signature = private_key.dsa_sign_asn1(OpenSSL::Digest::SHA256.digest(signing_input))
  raw_signature = OpenSSL::ASN1.decode(signature).value.map do |integer|
    bytes = integer.value.to_s(2)
    bytes = bytes[-32, 32] if bytes.bytesize > 32
    bytes.rjust(32, "\0")
  end.join
  "#{signing_input}.#{b64url(raw_signature)}"
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

def fetch_all(path, token, query = {})
  items = []
  next_url = nil
  loop do
    body = next_url ? api_get(next_url, token) : api_get(path, token, query)
    items.concat(body.fetch("data", []))
    next_url = body.dig("links", "next")
    break if next_url.to_s.empty?
  end
  items
end

def screenshot_inventory(localization, token)
  localization_id = localization.fetch("id")
  sets = fetch_all(
    "/v1/appStoreVersionLocalizations/#{localization_id}/appScreenshotSets",
    token,
    "limit" => "200"
  )
  {
    "id" => localization_id,
    "locale" => localization.dig("attributes", "locale"),
    "screenshotSets" => sets.map do |set|
      screenshots = fetch_all(
        "/v1/appScreenshotSets/#{set.fetch("id")}/appScreenshots",
        token,
        "limit" => "200"
      )
      {
        "id" => set.fetch("id"),
        "displayType" => set.dig("attributes", "screenshotDisplayType"),
        # API 的返回顺序就是当前展示顺序，显式保存 index 便于上传后核对。
        "screenshots" => screenshots.each_with_index.map do |screenshot, index|
          attributes = screenshot.fetch("attributes", {})
          {
            "id" => screenshot.fetch("id"),
            "index" => index,
            "fileName" => attributes["fileName"],
            "fileSize" => attributes["fileSize"],
            "sourceFileChecksum" => attributes["sourceFileChecksum"],
            "assetDeliveryState" => attributes["assetDeliveryState"],
            "imageAsset" => attributes["imageAsset"]
          }
        end
      }
    end
  }
end

options = parse_options
token = jwt
apps = fetch_all(
  "/v1/apps",
  token,
  "filter[bundleId]" => options.bundle_id,
  "limit" => "200"
)
fail_with("app not found for bundle id #{options.bundle_id}") if apps.empty?
fail_with("multiple apps found for bundle id #{options.bundle_id}") if apps.length > 1

app = apps.fetch(0)
app_id = app.fetch("id")
versions = fetch_all(
  "/v1/apps/#{app_id}/appStoreVersions",
  token,
  "filter[platform]" => "IOS",
  "limit" => "200"
)
beta_localizations = fetch_all(
  "/v1/apps/#{app_id}/betaAppLocalizations",
  token,
  "limit" => "200"
)

inventory = {
  "schemaVersion" => 1,
  "capturedAt" => Time.now.utc.iso8601,
  "app" => {
    "id" => app_id,
    "bundleId" => app.dig("attributes", "bundleId"),
    "name" => app.dig("attributes", "name"),
    "primaryLocale" => app.dig("attributes", "primaryLocale")
  },
  "betaAppLocalizations" => beta_localizations.map do |localization|
    {
      "id" => localization.fetch("id"),
      "attributes" => localization.fetch("attributes", {})
    }
  end,
  "appStoreVersions" => versions.map do |version|
    version_id = version.fetch("id")
    localizations = fetch_all(
      "/v1/appStoreVersions/#{version_id}/appStoreVersionLocalizations",
      token,
      "limit" => "200"
    )
    {
      "id" => version_id,
      "attributes" => version.fetch("attributes", {}),
      "localizations" => localizations.map { |localization| screenshot_inventory(localization, token) }
    }
  end
}

output = File.expand_path(options.output)
File.write(output, JSON.pretty_generate(inventory) + "\n")
puts "ASC_SCREENSHOT_INVENTORY=#{output}"
puts "ASC_APP_ID=#{app_id}"
puts "ASC_VERSION_COUNT=#{versions.length}"
puts "ASC_BETA_LOCALIZATION_COUNT=#{beta_localizations.length}"
