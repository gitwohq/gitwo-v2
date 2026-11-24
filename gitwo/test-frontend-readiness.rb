#!/usr/bin/env ruby
# frozen_string_literal: true

# Local, deterministic HTTP and RFC6455 fixtures; never use external hosts.
require 'tmpdir'
require 'fileutils'
require 'json'
require 'socket'
require 'base64'
require 'digest/sha1'
require_relative 'frontend-readiness'

def assert(condition, label)
  raise "Frontend readiness regression: #{label}" unless condition
end

def write(root, relative, content)
  path = File.join(root, relative)
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, content)
end

Dir.mktmpdir('gitwo-readiness.') do |root|
  write(root, 'Gemfile', "gem 'rails'\ngem 'importmap-rails'\n")
  write(root, 'config/importmap.rb', 'pin "application"')
  importmap = GitwoFrontendReadiness.probe(root)
  assert(importmap['status'] == 'not_applicable', 'Importmap cannot require a dev server')
  assert(importmap['checks'].first['status'] == 'not_applicable', 'Importmap readiness status')

  write(root, 'Gemfile', "gem 'rails'\ngem 'jsbundling-rails'\n")
  FileUtils.rm_f(File.join(root, 'config/importmap.rb'))
  write(root, 'package.json', JSON.generate(
    'devDependencies' => { 'esbuild' => '^0.24.0' },
    'scripts' => { 'build' => 'esbuild app.js --bundle --outfile=app/assets/builds/app.js' }
  ))
  write(root, 'Procfile.dev', "web: bin/rails server\njs: yarn build --watch\n")
  empty = GitwoFrontendReadiness.probe(root)
  assert(empty['status'] == 'failed', 'missing esbuild outputs must be reported')
  assert(empty['checks'][0]['status'] == 'no_build_artifacts', 'missing esbuild artifact evidence')

  write(root, 'app/assets/builds/application.js', '// app build')
  observed = GitwoFrontendReadiness.probe(root)
  assert(observed['status'] == 'unverified', 'artifact alone cannot prove watcher health')
  assert(observed['checks'][0]['status'] == 'artifacts_observed', 'build artifact inventory')
  assert(observed['readiness'] == 'not_verified', 'false watcher ready claim')

  FileUtils.rm_f(File.join(root, 'app/assets/builds/application.js'))
  File.symlink('/dev/null', File.join(root, 'app/assets/builds/application.js'))
  missing = GitwoFrontendReadiness.probe(root)
  assert(missing['status'] == 'failed', 'symlinked build artifacts must be ignored')
  FileUtils.rm_f(File.join(root, 'app/assets/builds/application.js'))

  write(root, 'Gemfile', "gem 'rails'\ngem 'vite_rails'\n")
  write(root, 'package.json', JSON.generate(
    'devDependencies' => { 'vite' => '^6.0.0' },
    'scripts' => { 'dev' => 'vite --host 127.0.0.1' }
  ))
  write(root, 'Procfile.dev', "web: bin/rails server\nvite: yarn dev\n")
  unknown = GitwoFrontendReadiness.probe(root)
  assert(unknown['status'] == 'unverified', 'Vite without URL should not claim HTTP ready')
  assert(unknown['checks'][0]['status'] == 'not_configured', 'Vite needs endpoint config')

  server = TCPServer.new('127.0.0.1', 0)
  port = server.addr[1]
  client = Thread.new do
    3.times do |iteration|
      socket = server.accept
      begin
        request = +''
        until request.include?("\r\n\r\n") || request.bytesize >= 8192
          request << socket.readpartial(1024)
        end
        if request.match?(/^Upgrade:\s*websocket/i)
          key = request.match(/^Sec-WebSocket-Key:\s*(\S+)/i)&.captures&.first
          accept = Base64.strict_encode64(Digest::SHA1.digest(
            key.to_s + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'
          ))
          socket.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" \
                       "Connection: Upgrade\r\nSec-WebSocket-Accept: #{accept}\r\n\r\n")
        else
          socket.write("HTTP/1.1 #{iteration == 2 ? '404 Not Found' : '200 OK'}\r\n" \
                       "Content-Length: 2\r\nConnection: close\r\n\r\nOK")
        end
      ensure
        socket.close
      end
    end
  end
  begin
    http_url = "http://127.0.0.1:#{port}/@vite/client"
    ws_url = "ws://127.0.0.1:#{port}/"
    connected = GitwoFrontendReadiness.probe(root, frontend_url: http_url, hmr_url: ws_url)
    assert(connected['status'] == 'transport_verified', "local HTTP/WS transport: #{connected}")
    assert(connected['readiness'] == 'not_verified', 'HTTP/WS transport is not full HMR')
    assert(connected['checks'][0].dig('http', 'status') == 'http_reachable', 'HTTP probe')
    assert(connected['checks'][0].dig('websocket', 'status') == 'websocket_handshake_verified', 'WS handshake')

    status_404 = GitwoFrontendReadiness.probe(root, frontend_url: http_url)
    assert(status_404['status'] == 'failed', 'HTTP 404 must not be reported healthy')
  ensure
    server.close
    client.join(5)
    client.kill if client.alive?
  end

  [
    ['https://example.com/@vite/client', nil],
    ['http://localhost.evil.example/@vite/client', nil],
    ['file:///tmp/fake-assets', nil],
    ['http://user:pass@127.0.0.1:5173/', nil],
    ['http://127.0.0.1:5173/', 'ws://localhost:5173/']
  ].each do |frontend_url, hmr_url|
    refused = false
    begin
      GitwoFrontendReadiness.probe(root, frontend_url: frontend_url, hmr_url: hmr_url)
    rescue GitwoFrontendReadiness::UnsafeTarget
      refused = true
    end
    assert(refused, "unsafe or mismatched endpoint was accepted: #{frontend_url}")
  end

  write(root, 'Gemfile', "gem 'rails'\ngem 'importmap-rails'\n")
  write(root, 'config/importmap.rb', 'pin "application"')
  assert(GitwoFrontendReadiness.probe(root)['status'] == 'not_applicable', 'no external JS watcher')
end

puts '[PASS] frontend readiness: Importmap, esbuild artifact evidence, Vite HTTP/WebSocket transport, 404 failure, safe local URL restrictions'
