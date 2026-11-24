#!/usr/bin/env ruby
# frozen_string_literal: true

# Read-only, opt-in frontend probes. Network targets must resolve exclusively
# to loopback. Static discovery never executes application-controlled scripts.
require 'json'
require 'net/http'
require 'uri'
require 'socket'
require 'ipaddr'
require 'openssl'
require 'base64'
require 'digest/sha1'
require 'securerandom'
require_relative 'frontend-detection'

module GitwoFrontendReadiness
  class UnsafeTarget < StandardError; end
  module_function

  def require_local_url!(raw, schemes)
    value = URI.parse(raw)
    raise UnsafeTarget, 'Unsupported URL scheme' unless schemes.include?(value.scheme)
    raise UnsafeTarget, 'URL must not have credentials, fragment or query' if
      value.userinfo || value.fragment || value.query
    host = value.host.to_s.downcase
    raise UnsafeTarget, 'URL must point to loopback or a .localhost hostname' unless
      host == 'localhost' || host == '127.0.0.1' || host == '::1' ||
      host.match?(/\A[a-z0-9-]+(?:\.[a-z0-9-]+)*\.localhost\z/)
    addresses = Addrinfo.getaddrinfo(host, value.port, nil, :STREAM)
    raise UnsafeTarget, 'No local address resolved' if addresses.empty?
    raise UnsafeTarget, 'Non-loopback DNS resolution refused' unless
      addresses.all? { |entry| IPAddr.new(entry.ip_address).loopback? }
    value
  rescue URI::InvalidURIError, SocketError, ArgumentError => error
    raise UnsafeTarget, "Invalid local frontend URL: #{error.message}"
  end

  def verified_loopback_ip(value)
    addresses = Addrinfo.getaddrinfo(value.host, value.port, nil, :STREAM)
    raise UnsafeTarget, 'No local address resolved' if addresses.empty?
    raise UnsafeTarget, 'Non-loopback DNS resolution refused' unless
      addresses.all? { |entry| IPAddr.new(entry.ip_address).loopback? }
    addresses.first.ip_address
  rescue SocketError, ArgumentError => error
    raise UnsafeTarget, "Cannot resolve local frontend: #{error.message}"
  end

  def local_ca_file
    path = File.join(Dir.home, '.portless', 'ca.pem')
    return nil unless File.exist?(path)
    raise UnsafeTarget, 'Unsafe local Portless CA' if File.symlink?(path) ||
      !File.file?(path) || File.size(path) > 1_000_000
    path
  end

  def http_probe(value)
    http = Net::HTTP.new(value.host, value.port, nil)
    # Pin the verified loopback address to avoid DNS rebinding between the
    # validation and the connection. The original hostname remains the TLS SNI.
    http.ipaddr = verified_loopback_ip(value)
    http.open_timeout = 2
    http.read_timeout = 3
    if value.scheme == 'https'
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      ca = local_ca_file
      http.ca_file = ca if ca
    end
    response = http.request(Net::HTTP::Get.new(value.request_uri.empty? ? '/' : value.request_uri))
    code = response.code.to_i
    {
      'status' => (200..399).cover?(code) ? 'http_reachable' : 'unexpected_status',
      'http_code' => code,
      'evidence' => 'Real HTTP request with TLS certificate verification when HTTPS'
    }
  rescue SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError, Timeout::Error => error
    { 'status' => 'unreachable', 'reason' => error.class.name }
  end

  def websocket_probe(value)
    key = Base64.strict_encode64(SecureRandom.random_bytes(16))
    socket = Socket.tcp(verified_loopback_ip(value), value.port, connect_timeout: 2)
    if value.scheme == 'wss'
      context = OpenSSL::SSL::SSLContext.new
      context.verify_mode = OpenSSL::SSL::VERIFY_PEER
      context.ca_file = local_ca_file if local_ca_file
      socket = OpenSSL::SSL::SSLSocket.new(socket, context)
      socket.hostname = value.host
      socket.sync_close = true
      socket.connect
      socket.post_connection_check(value.host)
    end
    path = value.request_uri.empty? ? '/' : value.request_uri
    host = value.host.include?(':') ? "[#{value.host}]" : value.host
    socket.write("GET #{path} HTTP/1.1\r\nHost: #{host}:#{value.port}\r\n" \
                 "Upgrade: websocket\r\nConnection: Upgrade\r\n" \
                 "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: #{key}\r\n\r\n")
    header = +''
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
    until header.include?("\r\n\r\n") || header.bytesize > 8192
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      raise Timeout::Error if remaining <= 0 || !IO.select([socket], nil, nil, remaining)
      header << socket.readpartial(1024)
    end
    status = header.lines.first.to_s
    accept = header.match(/^Sec-WebSocket-Accept:\s*(.+?)\s*\r?$/i)&.captures&.first
    expected = Base64.strict_encode64(Digest::SHA1.digest(
      key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'
    ))
    valid = status.match?(/\AHTTP\/1\.[01] 101(?:\s|$)/) &&
      header.match?(/^Upgrade:\s*websocket\s*\r?$/i) &&
      header.match?(/^Connection:\s*.*\bUpgrade\b/i) && accept == expected
    {
      'status' => valid ? 'websocket_handshake_verified' : 'handshake_failed',
      'evidence' => 'RFC6455 Upgrade/Accept handshake only; HMR event delivery not verified'
    }
  rescue SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError, Timeout::Error => error
    { 'status' => 'unreachable', 'reason' => error.class.name }
  ensure
    socket&.close
  end

  def safe_artifacts(root, integration, bundler)
    patterns = if integration == 'cssbundling-rails' || integration == 'tailwindcss-rails' ||
                  %w[tailwindcss sass postcss].include?(bundler)
                 %w[app/assets/builds/*.css app/assets/tailwind/*.css]
               elsif bundler == 'webpack' || bundler == 'rspack'
                 %w[app/assets/builds/*.js public/packs/*.js public/assets/*.js]
               else
                 %w[app/assets/builds/*.js]
               end
    # Never descend into user-controlled symlinked directories.
    patterns.flat_map { |pattern| Dir.glob(File.join(root, pattern)) }.first(500).filter_map do |path|
      relative = path.delete_prefix("#{root}/")
      relative if GitwoFrontendDetection.safe_file?(root, relative)
    end.uniq.sort
  end

  def probe(root, frontend_url: nil, hmr_url: nil)
    raise UnsafeTarget, 'Workspace path must be an absolute directory' unless
      root.start_with?('/') && File.directory?(root) && !File.symlink?(root)
    gemfile = GitwoFrontendDetection.read(root, 'Gemfile').to_s
    lock = GitwoFrontendDetection.read(root, 'Gemfile.lock').to_s
    detected, = GitwoFrontendDetection.discover(root, gemfile: gemfile, lock: lock)
    pipelines = detected.fetch('pipelines')
    dev_servers = pipelines.select { |p| p['mode'] == 'dev_server' }
    if frontend_url && dev_servers.size != 1
      raise UnsafeTarget, 'An explicit frontend URL requires exactly one detected dev-server pipeline'
    end
    raise UnsafeTarget, 'HMR URL requires --frontend-url' if hmr_url && !frontend_url
    http_url = frontend_url && require_local_url!(frontend_url, %w[http https])
    ws_url = hmr_url && require_local_url!(hmr_url, %w[ws wss])
    if http_url && ws_url
      raise UnsafeTarget, 'HMR host must match the verified frontend hostname' unless
        http_url.host.downcase == ws_url.host.downcase
      raise UnsafeTarget, 'HTTPS frontend requires WSS for secure HMR transport' if
        http_url.scheme == 'https' && ws_url.scheme != 'wss'
    end
    results = pipelines.map do |p|
      result = {
        'integration' => p.fetch('integration'),
        'bundler' => p.fetch('bundler'),
        'mode' => p.fetch('mode'),
        'processes' => p.fetch('processes'),
        'readiness' => 'not_verified'
      }
      case p['mode']
      when 'no_build'
        result['status'] = 'not_applicable'
      when 'watcher', 'build_only'
        assets = safe_artifacts(root, p['integration'], p['bundler'])
        result['status'] = assets.empty? ? 'no_build_artifacts' : 'artifacts_observed'
        result['artifacts'] = assets
        result['note'] = 'Artifact existence does not prove initial compilation after launcher startup or live watch health'
      when 'dev_server'
        if http_url
          result['http'] = http_probe(http_url)
          result['websocket'] = websocket_probe(ws_url) if ws_url
          result['status'] = if result['http']['status'] != 'http_reachable'
                               'http_failed'
                             elsif ws_url && result['websocket']['status'] != 'websocket_handshake_verified'
                               'websocket_failed'
                             else
                               'transport_verified'
                             end
          result['note'] = 'HTTP/WS transport is not proof that HMR events or assets update correctly'
        else
          result['status'] = 'not_configured'
          result['note'] = 'Explicit loopback frontend URL required; no endpoint inferred from source code'
        end
      else
        result['status'] = 'unknown_mode'
      end
      result
    end
    status = if results.empty? || results.all? { |p| p['status'] == 'not_applicable' }
               'not_applicable'
             elsif results.any? { |p| %w[http_failed websocket_failed no_build_artifacts].include?(p['status']) }
               'failed'
             elsif results.all? { |p| %w[transport_verified not_applicable].include?(p['status']) }
               'transport_verified'
             else
               'unverified'
             end
    {
      'status' => status,
      'workspace' => File.basename(root),
      'checks' => results,
      'scope' => 'read_only_transport_and_artifact_evidence',
      'readiness' => 'not_verified'
    }
  end

  def main
    root = ARGV.shift
    raise UnsafeTarget, 'Usage: frontend-readiness.rb WORKSPACE [--frontend-url=...] [--hmr-url=...]' unless root
    options = {}
    ARGV.each do |arg|
      case arg
      when /\A--frontend-url=(.+)\z/ then options[:frontend_url] = Regexp.last_match(1)
      when /\A--hmr-url=(.+)\z/ then options[:hmr_url] = Regexp.last_match(1)
      else raise UnsafeTarget, "Unknown frontend readiness argument: #{arg}"
      end
    end
    puts JSON.generate(probe(root, **options))
  rescue UnsafeTarget => error
    warn "Gitwo frontend readiness: #{error.message}"
    exit 2
  end
end

GitwoFrontendReadiness.main if $PROGRAM_NAME == __FILE__
