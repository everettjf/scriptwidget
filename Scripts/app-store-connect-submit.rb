#!/usr/bin/env ruby
# frozen_string_literal: true

require "base64"
require "json"
require "net/http"
require "openssl"
require "optparse"
require "uri"

API_ROOT = "https://api.appstoreconnect.apple.com/v1"
POLL_INTERVAL = Integer(ENV.fetch("APP_STORE_CONNECT_POLL_INTERVAL", "30"))
POLL_TIMEOUT = Integer(ENV.fetch("APP_STORE_CONNECT_POLL_TIMEOUT", "3600"))

def abort_with(message)
  warn "error: #{message}"
  exit 1
end

options = { platforms: [] }
OptionParser.new do |parser|
  parser.on("--bundle-id ID") { |v| options[:bundle_id] = v }
  parser.on("--version VERSION") { |v| options[:version] = v }
  parser.on("--build BUILD") { |v| options[:build] = v }
  parser.on("--platform PLATFORM") { |v| options[:platforms] << v }
end.parse!
%i[bundle_id version build].each { |key| abort_with("--#{key.to_s.tr('_', '-')} is required") unless options[key] }
abort_with("at least one --platform is required") if options[:platforms].empty?

key_id = ENV.fetch("APP_STORE_CONNECT_API_KEY_ID")
issuer_id = ENV.fetch("APP_STORE_CONNECT_API_ISSUER_ID")
key_path = ENV.fetch("APP_STORE_CONNECT_API_KEY_PATH")

def base64url(value)
  Base64.urlsafe_encode64(value, padding: false)
end

def jwt(key_id, issuer_id, key_path)
  now = Time.now.to_i
  header = base64url(JSON.generate(alg: "ES256", kid: key_id, typ: "JWT"))
  payload = base64url(JSON.generate(iss: issuer_id, iat: now, exp: now + 1_100, aud: "appstoreconnect-v1"))
  signing_input = "#{header}.#{payload}"
  key = OpenSSL::PKey.read(File.binread(key_path))
  sequence = OpenSSL::ASN1.decode(key.sign(OpenSSL::Digest::SHA256.new, signing_input))
  signature = sequence.value.map { |part| part.value.to_i.to_s(2).rjust(32, "\0") }.join
  "#{signing_input}.#{base64url(signature)}"
end

class Client
  def initialize(token_proc)
    @token_proc = token_proc
  end

  def request(method, path, query: nil, body: nil, expected: [200])
    uri = URI("#{API_ROOT}#{path}")
    uri.query = URI.encode_www_form(query) if query
    request_class = { get: Net::HTTP::Get, post: Net::HTTP::Post, patch: Net::HTTP::Patch }.fetch(method)
    request = request_class.new(uri)
    request["Authorization"] = "Bearer #{@token_proc.call}"
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(body) if body
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(request) }
    unless expected.include?(response.code.to_i)
      detail = JSON.parse(response.body).fetch("errors", []).map { |e| e["detail"] || e["title"] }.join("; ") rescue response.body
      abort_with("App Store Connect #{method.upcase} #{path} returned #{response.code}: #{detail}")
    end
    response.body.empty? ? nil : JSON.parse(response.body)
  end
end

token_proc = -> { jwt(key_id, issuer_id, key_path) }
client = Client.new(token_proc)
apps = client.request(:get, "/apps", query: { "filter[bundleId]" => options[:bundle_id], "limit" => 2 }).fetch("data")
abort_with("app not found for bundle ID #{options[:bundle_id]}") if apps.empty?
abort_with("multiple apps found for bundle ID #{options[:bundle_id]}") unless apps.one?
app_id = apps.first.fetch("id")

options[:platforms].each do |platform|
  prereleases = client.request(:get, "/preReleaseVersions", query: {
    "filter[app]" => app_id, "filter[version]" => options[:version], "filter[platform]" => platform, "limit" => 2
  }).fetch("data")
  abort_with("#{platform} prerelease #{options[:version]} not found") unless prereleases.one?

  prerelease_id = prereleases.first.fetch("id")
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + POLL_TIMEOUT
  build = nil
  loop do
    builds = client.request(:get, "/builds", query: {
      "filter[preReleaseVersion]" => prerelease_id, "filter[version]" => options[:build],
      "fields[builds]" => "version,processingState", "limit" => 2
    }).fetch("data")
    build = builds.find { |item| item.dig("attributes", "processingState") == "VALID" }
    break if build
    abort_with("timed out waiting for #{platform} build #{options[:build]}") if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    state = builds.first&.dig("attributes", "processingState") || "not visible"
    warn "Waiting for #{platform} build #{options[:build]} (#{state})..."
    sleep POLL_INTERVAL
  end

  versions = client.request(:get, "/apps/#{app_id}/appStoreVersions", query: {
    "filter[platform]" => platform, "filter[versionString]" => options[:version], "limit" => 2
  }).fetch("data")
  if versions.empty?
    created = client.request(:post, "/appStoreVersions", expected: [201], body: {
      data: { type: "appStoreVersions", attributes: { platform: platform, versionString: options[:version], releaseType: "MANUAL" },
              relationships: { app: { data: { type: "apps", id: app_id } } } }
    })
    version_id = created.dig("data", "id")
  else
    abort_with("multiple #{platform} App Store versions found") unless versions.one?
    version_id = versions.first.fetch("id")
  end

  client.request(:patch, "/appStoreVersions/#{version_id}/relationships/build", expected: [204], body: {
    data: { type: "builds", id: build.fetch("id") }
  })
  submission = client.request(:post, "/reviewSubmissions", expected: [201], body: {
    data: { type: "reviewSubmissions", attributes: { platform: platform },
            relationships: { app: { data: { type: "apps", id: app_id } } } }
  })
  submission_id = submission.dig("data", "id")
  client.request(:post, "/reviewSubmissionItems", expected: [201], body: {
    data: { type: "reviewSubmissionItems", relationships: {
      reviewSubmission: { data: { type: "reviewSubmissions", id: submission_id } },
      appStoreVersion: { data: { type: "appStoreVersions", id: version_id } }
    } }
  })
  client.request(:patch, "/reviewSubmissions/#{submission_id}", body: {
    data: { type: "reviewSubmissions", id: submission_id, attributes: { submitted: true } }
  })
  puts "✓ Submitted #{platform} #{options[:version]} (#{options[:build]})"
end
