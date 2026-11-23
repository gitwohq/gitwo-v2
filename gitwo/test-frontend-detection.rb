#!/usr/bin/env ruby
# frozen_string_literal: true

# Read-only frontend detection regression suite; no Rails/Node installation needed.
require 'tmpdir'
require 'fileutils'
require 'json'
require 'open3'
require_relative 'frontend-detection'
require_relative 'detect'

def assert(condition, description)
  raise "Frontend detection regression: #{description}" unless condition
end

def write(root, path, content)
  destination = File.join(root, path)
  FileUtils.mkdir_p(File.dirname(destination))
  File.write(destination, content)
end

def project(parent, name, files = {})
  root = File.join(parent, name)
  FileUtils.mkdir_p(File.join(root, 'config'))
  system('git', '-C', root, 'init', '-q', '-b', 'main', exception: true)
  system('git', '-C', root, 'config', 'user.name', 'Gitwo fixture', exception: true)
  system('git', '-C', root, 'config', 'user.email', 'fixture@example.invalid', exception: true)
  write(root, 'Gemfile', "gem 'rails'\ngem 'pg'\n")
  write(root, 'config/application.rb', '# Rails fixture')
  files.each { |path, contents| write(root, path, contents) }
  system('git', '-C', root, 'add', '.', exception: true)
  system('git', '-C', root, 'commit', '-qm', 'Initial fixture', exception: true)
  root
end

def inventory(root)
  GitwoDetection.detect(root)
end

def frontend(result)
  result.fetch('detected').fetch('frontend').fetch('value')
end

def pipeline(result, integration, bundler, mode)
  item = frontend(result).fetch('pipelines').find do |entry|
    entry['integration'] == integration && entry['bundler'] == bundler
  end
  assert(item, "missing pipeline #{integration}/#{bundler}: #{frontend(result)}")
  assert(item.fetch('mode') == mode, "unexpected mode for #{integration}/#{bundler}: #{item}")
  assert(item.fetch('readiness') == 'not_verified', 'claimed unverified frontend readiness')
  expected_hmr = mode == 'dev_server' ? 'unverified' : 'not_applicable'
  assert(item.fetch('hmr') == expected_hmr, "incorrect HMR for #{item}")
  assert(item.fetch('evidence').all? { |x| x.is_a?(String) }, 'invalid evidence')
  item
end

def notice(result, code, status)
  item = result.fetch('notices').find { |entry| entry['code'] == code }
  assert(item && item.fetch('status') == status, "missing notice #{code}: #{result['notices']}")
  item
end

Dir.mktmpdir('gitwo-frontend.') do |tmp|
  plain = project(tmp, 'plain')
  p = inventory(plain)
  assert(frontend(p)['pipelines'].empty?, 'bare Rails falsely has JS bundler')
  assert(frontend(p)['mode'] == 'unknown', 'bare Rails should not assume Importmap')

  importmap = project(tmp, 'importmap', {
    'Gemfile' => "gem 'rails'\ngem 'pg'\ngem 'importmap-rails'\n",
    'config/importmap.rb' => 'pin "application"'
  })
  p = inventory(importmap)
  pipeline(p, 'importmap-rails', 'none', 'no_build')
  assert(p['notices'].empty?, 'Importmap-only project should not warn about HMR')

  esbuild = project(tmp, 'esbuild', {
    'Gemfile' => "gem 'rails'\ngem 'pg'\ngem 'jsbundling-rails'\ngem 'cssbundling-rails'\n",
    'package.json' => JSON.generate({
      'scripts' => {
        'build' => 'esbuild app/javascript/application.js --bundle --outfile=app/assets/builds/application.js',
        'build:css' => 'tailwindcss -i app/assets/stylesheets/input.css -o app/assets/builds/application.css'
      },
      'devDependencies' => { 'esbuild' => '^0.24.0', 'tailwindcss' => '^3.4.0' }
    }),
    'Procfile.dev' => "web: bin/rails server\njs: yarn build --watch\ncss: yarn build:css --watch\n"
  })
  p = inventory(esbuild)
  pipeline(p, 'jsbundling-rails', 'esbuild', 'watcher')
  pipeline(p, 'cssbundling-rails', 'tailwindcss', 'watcher')
  assert(frontend(p)['mode'] == 'mixed', 'multiple pipelines not represented')
  assert(!frontend(p)['ambiguous'], 'known watcher modes should not be ambiguous')
  assert(frontend(p)['processes'] == %w[css js web], 'lost Procfile process names')
  assert(p['notices'].empty?, 'esbuild watcher incorrectly triggers HMR notice')
  before = `git -C "#{esbuild}" status --porcelain --untracked-files=all`
  stdout, stderr, status = Open3.capture3('ruby', File.join(__dir__, 'onboard.rb'),
                                         'init', '--scope=local', "--project=#{esbuild}",
                                         '--dry-run', '--json')
  assert(status.success?, "read-only init failed: #{stderr}")
  d = JSON.parse(stdout).fetch('detection')
  assert(frontend(d)['pipelines'].size == 2, 'onboarding omitted frontend inventory')
  after = `git -C "#{esbuild}" status --porcelain --untracked-files=all`
  assert(before == after, 'read-only detection modified project files')

  vite = project(tmp, 'vite', {
    'Gemfile' => "gem 'rails'\ngem 'pg'\ngem 'vite_rails'\n",
    'vite.config.ts' => 'export default {}',
    'package.json' => JSON.generate({
      'devDependencies' => { 'vite' => '^6.0.0' },
      'scripts' => { 'dev' => 'vite --host 127.0.0.1' }
    }),
    'Procfile.dev' => "web: bin/rails server\nvite: yarn dev\n"
  })
  p = inventory(vite)
  pipeline(p, 'vite_rails', 'vite', 'dev_server')
  notice(p, 'frontend_hmr_not_verified', 'detected_not_configured')
  stdout, stderr, status = Open3.capture3('ruby', File.join(__dir__, 'onboard.rb'),
                                         'detect', "--project=#{vite}")
  assert(status.success? && stderr.include?('Frontend dev server detected'), 'detect CLI missing frontend notice')
  assert(stdout.include?('frontend'), 'detect CLI missing frontend evidence')
  stdout, stderr, status = Open3.capture3({ 'HOME' => tmp, 'XDG_CONFIG_HOME' => File.join(tmp, 'xdg') },
                                         'ruby', File.join(__dir__, 'onboard.rb'),
                                         'init', '--scope=local', "--project=#{vite}", '--yes')
  assert(status.success? && stderr.include?('Frontend dev server detected'), 'init CLI missing HMR notice')

  webpacker = project(tmp, 'webpacker', {
    'Gemfile' => "gem 'rails'\ngem 'pg'\ngem 'webpacker'\n",
    'config/webpacker.yml' => "default:\n  source_path: app/javascript\n",
    'Procfile.dev' => "web: bin/rails server\nwebpack: bin/webpack-dev-server\n"
  })
  pipeline(inventory(webpacker), 'webpacker', 'webpack', 'dev_server')

  shaka = project(tmp, 'shaka', {
    'Gemfile' => "gem 'rails'\ngem 'pg'\ngem 'shakapacker'\n",
    'config/shakapacker.yml' => "default:\n  source_path: app/javascript\n",
    'package.json' => JSON.generate({ 'devDependencies' => { 'webpack' => '^5.0.0' } }),
    'Procfile.dev' => "web: bin/rails server\njs: yarn webpack --watch\n"
  })
  pipeline(inventory(shaka), 'shakapacker', 'webpack', 'watcher')

  mixed = project(tmp, 'mixed', {
    'Gemfile' => "gem 'rails'\ngem 'pg'\ngem 'importmap-rails'\ngem 'jsbundling-rails'\n",
    'config/importmap.rb' => 'pin "application"',
    'package.json' => JSON.generate({
      'devDependencies' => { 'esbuild' => '^0.24.0', 'webpack' => '^5.0.0' },
      'scripts' => {
        'build' => 'esbuild app.js --bundle --outfile=app/assets/builds/app.js',
        'webpack:watch' => 'webpack --watch'
      }
    }),
    'Procfile.dev' => "web: bin/rails s\nwebpack: yarn webpack:watch\njs: yarn build --watch\n"
  })
  p = inventory(mixed)
  pipeline(p, 'importmap-rails', 'none', 'no_build')
  pipeline(p, 'jsbundling-rails', 'esbuild', 'watcher')
  pipeline(p, 'jsbundling-rails', 'webpack', 'watcher')
  assert(frontend(p)['pipelines'].size == 3, 'mixed frontend incorrectly collapsed')

  malformed = project(tmp, 'malformed', {
    'package.json' => '{"scripts":',
    'vite.config.js' => 'export default {}'
  })
  p = inventory(malformed)
  notice(p, 'frontend_package_metadata_invalid', 'ambiguous')
  assert(frontend(p)['ambiguous'], 'malformed package metadata not reported')

  symlinks = project(tmp, 'symlinks')
  FileUtils.mkdir_p(File.join(symlinks, 'bin'))
  File.symlink('/dev/null', File.join(symlinks, 'package.json'))
  File.symlink('/dev/null', File.join(symlinks, 'vite.config.ts'))
  File.symlink('/dev/null', File.join(symlinks, 'Procfile.dev'))
  File.symlink('/dev/null', File.join(symlinks, 'bin/dev'))
  p = inventory(symlinks)
  assert(frontend(p)['pipelines'].empty?, 'symlinked configs were trusted as evidence')
  assert(frontend(p)['launcher'].nil?, 'symlinked dev launcher was detected')

  malicious = project(tmp, 'malicious', {
    'Procfile.dev' => "web: touch #{File.join(tmp, 'NEVER_EXECUTED')}\n",
    'package.json' => JSON.generate({ 'scripts' => { 'dev' => "touch #{File.join(tmp, 'NEVER_EXECUTED')}" } })
  })
  inventory(malicious)
  assert(!File.exist?(File.join(tmp, 'NEVER_EXECUTED')), 'application code executed during discovery')
end

puts '[PASS] frontend detection: Vite, Webpacker, Shakapacker, esbuild, CSS, Importmap, mixed modes, malformed JSON and symlink safety'
