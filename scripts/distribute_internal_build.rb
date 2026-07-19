#!/usr/bin/env ruby
# frozen_string_literal: true

require "base64"
require "json"
require "net/http"
require "openssl"
require "open3"
require "tmpdir"
require "uri"

def abort_release(message)
  warn "TestFlight 内测分发失败：#{message}"
  exit 1
end

def required_env(name)
  value = ENV[name].to_s
  abort_release("缺少环境变量 #{name}") if value.empty?
  value
end

def base64url(value)
  Base64.urlsafe_encode64(value).delete("=")
end

def app_store_connect_token
  now = Time.now.to_i
  header = { alg: "ES256", kid: required_env("APP_STORE_CONNECT_API_KEY_ID"), typ: "JWT" }
  payload = {
    iss: required_env("APP_STORE_CONNECT_API_ISSUER_ID"),
    iat: now,
    exp: now + 1_200,
    aud: "appstoreconnect-v1"
  }
  signing_input = [base64url(header.to_json), base64url(payload.to_json)].join(".")
  key = OpenSSL::PKey.read(File.read(required_env("APP_STORE_CONNECT_API_KEY_PATH")))
  der = key.dsa_sign_asn1(OpenSSL::Digest::SHA256.digest(signing_input))

  # 核心逻辑：OpenSSL 返回 DER 编码签名，而 JWT ES256 要求固定 64 字节的 r+s。
  raw = OpenSSL::ASN1.decode(der).value.map do |integer|
    bytes = integer.value.to_s(2)
    bytes = bytes[-32, 32] if bytes.bytesize > 32
    bytes.rjust(32, "\0")
  end.join
  "#{signing_input}.#{base64url(raw)}"
end

class AscClient
  def initialize(&token_provider)
    @token_provider = token_provider
  end

  def get(path, query = {})
    request("GET", path, query: query)
  end

  def post(path, body)
    request("POST", path, body: body)
  end

  def patch(path, body, allowed_statuses: [])
    request("PATCH", path, body: body, allowed_statuses: allowed_statuses)
  end

  private

  def request(method, path, query: {}, body: nil, allowed_statuses: [])
    uri = URI::HTTPS.build(
      host: "api.appstoreconnect.apple.com",
      path: path,
      query: query.empty? ? nil : URI.encode_www_form(query)
    )
    request = Net::HTTP.const_get(method.capitalize).new(uri)
    # Apple 处理构建偶尔会超过 JWT 的 20 分钟有效期。每次请求重新签发短期
    # token，避免长轮询在构建即将可用时因为 401 中断。
    request["Authorization"] = "Bearer #{@token_provider.call}"
    if body
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(body)
    end
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(request) }
    status = response.code.to_i
    return {} if response.body.to_s.empty? && (status.between?(200, 299) || allowed_statuses.include?(status))

    parsed = JSON.parse(response.body)
    return parsed if status.between?(200, 299) || allowed_statuses.include?(status)

    abort_release("#{method} #{path} 返回 HTTP #{status}：#{JSON.pretty_generate(parsed)}")
  end
end

def command_output(*args)
  output, error, status = Open3.capture3(*args)
  abort_release("#{args.join(' ')} 执行失败：#{error}") unless status.success?
  output.strip
end

def ipa_metadata(ipa)
  abort_release("找不到 IPA：#{ipa}") unless File.file?(ipa)
  Dir.mktmpdir("mimi-ipa-") do |dir|
    command_output("unzip", "-q", ipa, "-d", dir)
    app = Dir.glob(File.join(dir, "Payload", "*.app")).first
    abort_release("IPA 中不存在 Payload/*.app") unless app
    plist = File.join(app, "Info.plist")
    return {
      bundle_id: command_output("/usr/libexec/PlistBuddy", "-c", "Print :CFBundleIdentifier", plist),
      version: command_output("/usr/libexec/PlistBuddy", "-c", "Print :CFBundleShortVersionString", plist),
      build: command_output("/usr/libexec/PlistBuddy", "-c", "Print :CFBundleVersion", plist)
    }
  end
end

expected_bundle_id = required_env("IOS_BUNDLE_ID")
group_id = required_env("TESTFLIGHT_BETA_GROUP_ID")
whats_new = required_env("TESTFLIGHT_WHATS_NEW")
ipa = ARGV.fetch(0) { abort_release("用法：distribute_internal_build.rb APP.ipa|--resume") }
metadata = if ipa == "--resume"
             # 上传成功后本地临时目录可能已被清理。恢复分发只需要精确定位 ASC
             # 中的构建，不应为了读取 Info.plist 再次归档或重复上传。
             {
               bundle_id: expected_bundle_id,
               version: required_env("TESTFLIGHT_RELEASE_VERSION"),
               build: required_env("TESTFLIGHT_BUILD_NUMBER")
             }
           else
             ipa_metadata(ipa)
           end
abort_release("Bundle ID 不匹配：#{metadata[:bundle_id]}") unless metadata[:bundle_id] == expected_bundle_id

client = AscClient.new { app_store_connect_token }
app = client.get("/v1/apps", { "filter[bundleId]" => expected_bundle_id, "limit" => "1" }).fetch("data").first
abort_release("App Store Connect 中找不到 #{expected_bundle_id}") unless app

# 等待 Apple 完成处理；上传和处理速度不可控，但不会重复归档或重复上传。
deadline = Time.now + 1_800
build = nil
loop do
  result = client.get("/v1/builds", {
    "filter[app]" => app.fetch("id"),
    "filter[preReleaseVersion.version]" => metadata[:version],
    "filter[version]" => metadata[:build],
    "limit" => "1"
  })
  build = result.fetch("data").first
  state = build&.dig("attributes", "processingState")
  puts "等待 Apple 处理：#{metadata[:version]} (#{metadata[:build]}) state=#{state || 'NOT_FOUND'}"
  break if state == "VALID"
  abort_release("Apple 处理失败：#{state}") if %w[FAILED INVALID].include?(state)
  abort_release("等待构建 VALID 超时") if Time.now >= deadline
  sleep 30
end

build_id = build.fetch("id")
client.patch("/v1/builds/#{build_id}", {
  data: { type: "builds", id: build_id, attributes: { usesNonExemptEncryption: false } }
}, allowed_statuses: [409])

localizations = client.get("/v1/builds/#{build_id}/betaBuildLocalizations", { "limit" => "20" }).fetch("data")
localization = localizations.find { |item| item.dig("attributes", "locale") == "zh-Hans" } || localizations.first
if localization
  client.patch("/v1/betaBuildLocalizations/#{localization.fetch('id')}", {
    data: {
      type: "betaBuildLocalizations",
      id: localization.fetch("id"),
      attributes: { whatsNew: whats_new }
    }
  })
else
  client.post("/v1/betaBuildLocalizations", {
    data: {
      type: "betaBuildLocalizations",
      attributes: { locale: "zh-Hans", whatsNew: whats_new },
      relationships: { build: { data: { type: "builds", id: build_id } } }
    }
  })
end

group = client.get("/v1/betaGroups/#{group_id}").fetch("data")
abort_release("目标组不是内部测试组") if group.dig("attributes", "isInternalGroup") == false
group_builds = client.get("/v1/betaGroups/#{group_id}/builds", { "limit" => "200" }).fetch("data")
unless group_builds.any? { |item| item.fetch("id") == build_id }
  client.post("/v1/betaGroups/#{group_id}/relationships/builds", {
    data: [{ type: "builds", id: build_id }]
  })
end

verified = client.get("/v1/betaGroups/#{group_id}/builds", { "limit" => "200" }).fetch("data")
abort_release("构建未成功关联内测组") unless verified.any? { |item| item.fetch("id") == build_id }
puts "Mimi TestFlight 内测发布成功：#{metadata[:version]} (#{metadata[:build]}) group=#{group.dig('attributes', 'name')}"
