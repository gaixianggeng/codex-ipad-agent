#!/usr/bin/env ruby
# frozen_string_literal: true

require "base64"
require "digest"
require "json"
require "net/http"
require "openssl"
require "optparse"
require "time"
require "uri"

Options = Struct.new(
  :bundle_id,
  :version,
  :screenshots_root,
  :apply,
  :replace_existing,
  keyword_init: true
)

LOCALES = %w[zh-Hans en-US].freeze
DISPLAY_FOLDERS = {
  "iphone-6.5" => "APP_IPHONE_65",
  "ipad-13" => "APP_IPAD_PRO_3GEN_129"
}.freeze
EDITABLE_STATES = %w[PREPARE_FOR_SUBMISSION DEVELOPER_REJECTED REJECTED METADATA_REJECTED].freeze

def fail_with(message)
  warn "ios-asc-publish-screenshots: #{message}"
  exit 1
end

def parse_options
  options = Options.new(apply: false, replace_existing: false)
  OptionParser.new do |opts|
    opts.banner = <<~TEXT
      Usage: ios_asc_publish_screenshots.rb \
        --bundle-id ID --version VERSION --screenshots-root PATH [--apply] [--replace-existing]

      默认只读预检；只有显式传入 --apply 才会创建新版本、语言和截图资源。
    TEXT
    opts.on("--bundle-id ID") { |value| options.bundle_id = value }
    opts.on("--version VERSION") { |value| options.version = value }
    opts.on("--screenshots-root PATH") { |value| options.screenshots_root = value }
    opts.on("--apply") { options.apply = true }
    opts.on("--replace-existing") { options.replace_existing = true }
  end.parse!

  fail_with("--bundle-id is required") if options.bundle_id.to_s.empty?
  fail_with("--version is required") if options.version.to_s.empty?
  fail_with("--screenshots-root is required") if options.screenshots_root.to_s.empty?
  options.screenshots_root = File.expand_path(options.screenshots_root)
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

def api_request(method, uri_or_path, token, body: nil, query: {})
  uri = if uri_or_path.start_with?("http")
          URI(uri_or_path)
        else
          URI::HTTPS.build(
            host: "api.appstoreconnect.apple.com",
            path: uri_or_path,
            query: query.empty? ? nil : URI.encode_www_form(query)
          )
        end
  request_class = {
    get: Net::HTTP::Get,
    post: Net::HTTP::Post,
    patch: Net::HTTP::Patch,
    delete: Net::HTTP::Delete
  }.fetch(method)
  request = request_class.new(uri)
  request["Authorization"] = "Bearer #{token}"
  if body
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(body)
  end
  response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(request) }
  parsed = response.body.to_s.empty? ? {} : JSON.parse(response.body)
  return parsed if response.code.to_i.between?(200, 299)

  fail_with("#{method.to_s.upcase} #{uri.path} failed: HTTP #{response.code} #{JSON.dump(parsed)}")
end

def fetch_all(path, token, query = {})
  items = []
  next_url = nil
  loop do
    body = next_url ? api_request(:get, next_url, token) : api_request(:get, path, token, query: query)
    items.concat(body.fetch("data", []))
    next_url = body.dig("links", "next")
    break if next_url.to_s.empty?
  end
  items
end

def validate_assets(root, version)
  manifest_path = File.join(root, "manifest.json")
  fail_with("manifest not found: #{manifest_path}") unless File.file?(manifest_path)
  manifest = JSON.parse(File.read(manifest_path))
  fail_with("manifest is not upload-ready") unless manifest["uploadReady"] == true
  fail_with("manifest targetVersion does not match #{version}") unless manifest["targetVersion"] == version
  fail_with("manifest locales do not match") unless manifest["locales"] == LOCALES

  expected_paths = []
  LOCALES.each do |locale|
    DISPLAY_FOLDERS.each_key do |folder|
      files = Dir.glob(File.join(root, locale, folder, "*.png")).sort
      fail_with("expected 5 PNG files in #{locale}/#{folder}, got #{files.length}") unless files.length == 5
      expected_paths.concat(files)
    end
  end

  records = manifest.fetch("files")
  fail_with("manifest must contain 20 file records") unless records.length == 20
  records_by_path = records.to_h { |record| [File.expand_path(record.fetch("path")), record] }
  expected_paths.each do |path|
    record = records_by_path[path]
    fail_with("manifest is missing #{path}") unless record
    actual = Digest::SHA256.file(path).hexdigest
    fail_with("SHA-256 mismatch for #{path}") unless actual == record.fetch("sha256")
  end
  expected_paths
end

def find_app(token, bundle_id)
  apps = fetch_all("/v1/apps", token, "filter[bundleId]" => bundle_id, "limit" => "200")
  fail_with("app not found for bundle id #{bundle_id}") if apps.empty?
  fail_with("multiple apps found for bundle id #{bundle_id}") if apps.length > 1
  apps.first
end

def find_version(token, app_id, version_string)
  versions = fetch_all(
    "/v1/apps/#{app_id}/appStoreVersions",
    token,
    "filter[platform]" => "IOS",
    "filter[versionString]" => version_string,
    "limit" => "200"
  )
  fail_with("multiple iOS versions found for #{version_string}") if versions.length > 1
  versions.first
end

def create_version(token, app_id, version_string)
  api_request(
    :post,
    "/v1/appStoreVersions",
    token,
    body: {
      data: {
        type: "appStoreVersions",
        attributes: {
          platform: "IOS",
          versionString: version_string,
          releaseType: "MANUAL"
        },
        relationships: {
          app: { data: { type: "apps", id: app_id } }
        }
      }
    }
  ).fetch("data")
end

def app_info_locales(token, app_id)
  infos = fetch_all("/v1/apps/#{app_id}/appInfos", token, "limit" => "200")
  infos.flat_map do |info|
    fetch_all("/v1/appInfos/#{info.fetch('id')}/appInfoLocalizations", token, "limit" => "200")
  end.map { |localization| localization.dig("attributes", "locale") }.compact.uniq
end

def version_localizations(token, version_id)
  fetch_all(
    "/v1/appStoreVersions/#{version_id}/appStoreVersionLocalizations",
    token,
    "limit" => "200"
  )
end

def create_version_localization(token, version_id, locale)
  api_request(
    :post,
    "/v1/appStoreVersionLocalizations",
    token,
    body: {
      data: {
        type: "appStoreVersionLocalizations",
        attributes: { locale: locale },
        relationships: {
          appStoreVersion: { data: { type: "appStoreVersions", id: version_id } }
        }
      }
    }
  ).fetch("data")
end

def screenshot_sets(token, localization_id)
  fetch_all(
    "/v1/appStoreVersionLocalizations/#{localization_id}/appScreenshotSets",
    token,
    "limit" => "200"
  )
end

def create_screenshot_set(token, localization_id, display_type)
  api_request(
    :post,
    "/v1/appScreenshotSets",
    token,
    body: {
      data: {
        type: "appScreenshotSets",
        attributes: { screenshotDisplayType: display_type },
        relationships: {
          appStoreVersionLocalization: {
            data: { type: "appStoreVersionLocalizations", id: localization_id }
          }
        }
      }
    }
  ).fetch("data")
end

def screenshots(token, set_id)
  fetch_all("/v1/appScreenshotSets/#{set_id}/appScreenshots", token, "limit" => "200")
end

def normalize_headers(raw_headers)
  case raw_headers
  when Array
    raw_headers.to_h { |header| [header.fetch("name"), header.fetch("value")] }
  when Hash
    raw_headers
  else
    {}
  end
end

def upload_operation(operation, bytes)
  uri = URI(operation.fetch("url"))
  method = operation.fetch("method").downcase.to_sym
  request_class = { put: Net::HTTP::Put, post: Net::HTTP::Post }.fetch(method)
  request = request_class.new(uri)
  normalize_headers(operation["requestHeaders"]).each { |name, value| request[name] = value }
  offset = operation.fetch("offset")
  length = operation.fetch("length")
  request.body = bytes.byteslice(offset, length)
  fail_with("invalid upload byte range #{offset}..#{offset + length}") unless request.body&.bytesize == length

  response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(request) }
  return if response.code.to_i.between?(200, 299)

  fail_with("asset upload failed: HTTP #{response.code}")
end

def reserve_and_upload_screenshot(token, set_id, path)
  bytes = File.binread(path)
  reservation = api_request(
    :post,
    "/v1/appScreenshots",
    token,
    body: {
      data: {
        type: "appScreenshots",
        attributes: { fileSize: bytes.bytesize, fileName: File.basename(path) },
        relationships: {
          appScreenshotSet: { data: { type: "appScreenshotSets", id: set_id } }
        }
      }
    }
  ).fetch("data")

  reservation.fetch("attributes").fetch("uploadOperations").each do |operation|
    upload_operation(operation, bytes)
  end
  screenshot_id = reservation.fetch("id")
  api_request(
    :patch,
    "/v1/appScreenshots/#{screenshot_id}",
    token,
    body: {
      data: {
        type: "appScreenshots",
        id: screenshot_id,
        attributes: {
          uploaded: true,
          sourceFileChecksum: Digest::MD5.hexdigest(bytes)
        }
      }
    }
  )
  screenshot_id
end

def asset_state(token, screenshot_id)
  api_request(:get, "/v1/appScreenshots/#{screenshot_id}", token)
    .dig("data", "attributes", "assetDeliveryState", "state")
end

def wait_for_assets(token, screenshot_ids, timeout: 300)
  deadline = Time.now + timeout
  pending = screenshot_ids.dup
  until pending.empty?
    pending.delete_if do |screenshot_id|
      state = asset_state(token, screenshot_id)
      fail_with("screenshot #{screenshot_id} processing failed") if state == "FAILED"
      %w[COMPLETE UPLOAD_COMPLETE].include?(state)
    end
    break if pending.empty?
    fail_with("timed out waiting for #{pending.length} screenshots") if Time.now >= deadline
    sleep 5
  end
end

options = parse_options
asset_paths = validate_assets(options.screenshots_root, options.version)
token = jwt
app = find_app(token, options.bundle_id)
app_id = app.fetch("id")
version = find_version(token, app_id, options.version)

puts "ASC_MODE=#{options.apply ? 'apply' : 'dry-run'}"
puts "ASC_APP_ID=#{app_id}"
puts "ASC_TARGET_VERSION=#{options.version}"
puts "ASC_ASSET_COUNT=#{asset_paths.length}"

unless options.apply
  puts "ASC_VERSION_EXISTS=#{!version.nil?}"
  puts "ASC_REPLACE_EXISTING=#{options.replace_existing}"
  puts "ASC_PLAN=create-version-if-missing,ensure-localizations,ensure-screenshot-sets,#{options.replace_existing ? 'replace-existing,' : ''}upload-20"
  if version
    version_id = version.fetch("id")
    puts "ASC_VERSION_ID=#{version_id}"
    puts "ASC_VERSION_STATE=#{version.dig('attributes', 'appStoreState')}"
    localizations = version_localizations(token, version_id)
    LOCALES.each do |locale|
      localization = localizations.find { |item| item.dig("attributes", "locale") == locale }
      next puts("ASC_EXISTING=#{locale}/missing-localization/0") unless localization

      sets = screenshot_sets(token, localization.fetch("id"))
      DISPLAY_FOLDERS.each_value do |display_type|
        set = sets.find { |item| item.dig("attributes", "screenshotDisplayType") == display_type }
        count = set ? screenshots(token, set.fetch("id")).length : 0
        puts "ASC_EXISTING=#{locale}/#{display_type}/#{count}"
      end
    end
  end
  exit 0
end

version ||= create_version(token, app_id, options.version)
version_id = version.fetch("id")
state = version.dig("attributes", "appStoreState")
if state && !EDITABLE_STATES.include?(state)
  fail_with("version #{options.version} is not editable: #{state}")
end

missing_app_info_locales = LOCALES - app_info_locales(token, app_id)
unless missing_app_info_locales.empty?
  fail_with("App Info is missing locales: #{missing_app_info_locales.join(', ')}")
end

localizations = version_localizations(token, version_id)
LOCALES.each do |locale|
  localizations << create_version_localization(token, version_id, locale) unless localizations.any? {
    |item| item.dig("attributes", "locale") == locale
  }
end

uploaded_ids = []
LOCALES.each do |locale|
  localization = localizations.find { |item| item.dig("attributes", "locale") == locale }
  localization_id = localization.fetch("id")
  sets = screenshot_sets(token, localization_id)

  DISPLAY_FOLDERS.each do |folder, display_type|
    set = sets.find { |item| item.dig("attributes", "screenshotDisplayType") == display_type }
    set ||= create_screenshot_set(token, localization_id, display_type)
    set_id = set.fetch("id")
    existing = screenshots(token, set_id)
    unless existing.empty?
      names = existing.map { |item| item.dig("attributes", "fileName") }.compact
      unless options.replace_existing
        fail_with("refusing to modify non-empty #{locale}/#{display_type}: #{names.join(', ')}")
      end
      existing.each do |item|
        puts "ASC_DELETE=#{locale}/#{display_type}/#{item.dig('attributes', 'fileName')}"
        api_request(:delete, "/v1/appScreenshots/#{item.fetch('id')}", token)
      end
    end

    Dir.glob(File.join(options.screenshots_root, locale, folder, "*.png")).sort.each do |path|
      puts "ASC_UPLOAD=#{locale}/#{display_type}/#{File.basename(path)}"
      uploaded_ids << reserve_and_upload_screenshot(token, set_id, path)
    end
  end
end

wait_for_assets(token, uploaded_ids)
puts "ASC_VERSION_ID=#{version_id}"
puts "ASC_UPLOADED_COUNT=#{uploaded_ids.length}"
puts "ASC_UPLOAD_COMPLETE=true"
