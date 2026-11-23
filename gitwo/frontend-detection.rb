# frozen_string_literal: true

# Read-only, evidence-based frontend inventory. Never execute application hooks,
# package scripts, Ruby code, webpack/Vite configurations or node binaries.
require 'json'

module GitwoFrontendDetection
  module_function

  MAX_FILE_BYTES = 1_000_000

  def safe_file?(root, relative)
    parts = relative.split('/')
    return false if parts.empty? || parts.any? { |part| part.empty? || part == '.' || part == '..' }

    current = root
    parts.each_with_index do |part, index|
      current = File.join(current, part)
      return false if File.symlink?(current)
      return false if index < parts.length - 1 && !File.directory?(current)
    end
    File.file?(current) && File.size(current) <= MAX_FILE_BYTES
  rescue SystemCallError
    false
  end

  def read(root, relative)
    return nil unless safe_file?(root, relative)

    File.read(File.join(root, relative), encoding: 'UTF-8').scrub
  rescue SystemCallError, EncodingError
    nil
  end

  def package_metadata(root)
    raw = read(root, 'package.json')
    return [[], {}, nil] if raw.nil?

    object = JSON.parse(raw)
    return [{}, {}, 'package.json is not a JSON object'] unless object.is_a?(Hash)

    dependencies = %w[dependencies devDependencies optionalDependencies].each_with_object([]) do |key, result|
      entries = object[key]
      result.concat(entries.keys) if entries.is_a?(Hash)
    end
    scripts = object['scripts'].is_a?(Hash) ? object['scripts'].select { |name, command|
      name.is_a?(String) && name.size <= 128 && command.is_a?(String) && command.size <= 2048
    } : {}
    [dependencies.uniq, scripts, nil]
  rescue JSON::ParserError
    [[], {}, 'package.json is malformed JSON']
  end

  def procfile_processes(root)
    raw = read(root, 'Procfile.dev')
    return {} unless raw

    raw.each_line.each_with_object({}) do |line, processes|
      match = line.match(/\A\s*([A-Za-z_][A-Za-z_0-9]*)\s*:\s*(.*?)\s*\z/)
      processes[match[1]] = match[2] if match && match[2].length <= 2048
    end
  end

  def config_files(root, names)
    names.select { |name| safe_file?(root, name) }
  end

  def gem?(gemfile, lock, name)
    pattern = Regexp.escape(name)
    gemfile.match?(/\bgem\s*['"]#{pattern}['"]/) ||
      lock.match?(/^    #{pattern} \(/)
  end

  def script_matches?(scripts, pattern)
    scripts.any? { |_name, command| pattern.match?(command) }
  end

  def process_matches(processes, scripts, pattern)
    # Process names, rather than their executable shell commands, are returned.
    # Referenced package scripts provide additional evidence without execution.
    processes.filter_map do |name, command|
      next name if pattern.match?(command)

      invocation = command.match(/\b(?:npm\s+run|yarn|pnpm(?:\s+run)?|bun(?:\s+run)?)\s+([\w:-]+)/)
      name if invocation && pattern.match?(scripts.fetch(invocation[1], ''))
    end.sort
  end

  def pipeline(integration, bundler, evidence, processes, mode)
    {
      'integration' => integration,
      'bundler' => bundler,
      'mode' => mode,
      'processes' => processes,
      'evidence' => evidence.uniq.sort,
      'confidence' => evidence.length > 1 ? 'high' : 'medium',
      # Readiness and HMR cannot be proven by static inspection.
      'readiness' => 'not_verified',
      'hmr' => mode == 'dev_server' ? 'unverified' : 'not_applicable'
    }
  end

  def discover(repo, gemfile:, lock:)
    dependencies, scripts, package_error = package_metadata(repo)
    processes = procfile_processes(repo)
    has = ->(name) { dependencies.include?(name) }
    detected = []
    notices = []

    vite_files = config_files(repo, %w[vite.config.ts vite.config.js vite.config.mts vite.config.mjs vite.config.cjs config/vite.json bin/vite])
    vite_gem = gem?(gemfile, lock, 'vite_rails') || gem?(gemfile, lock, 'vite_ruby')
    if vite_gem || has.call('vite') || !vite_files.empty?
      ps = process_matches(processes, scripts, /(?:\bbin\/vite\b|\bvite\s+(?:dev|serve)\b|\bvite\b(?:\s|$))/)
      evidence = vite_files
      evidence += ['Gemfile.lock / Gemfile'] if vite_gem
      evidence += ['package.json'] if has.call('vite')
      evidence << 'Procfile.dev' unless ps.empty?
      mode = ps.empty? ? (script_matches?(scripts, /\bvite(?:\s+(?:dev|serve))?(?:\s|$)/) ? 'dev_server' : 'unknown') : 'dev_server'
      detected << pipeline(vite_gem ? 'vite_rails' : 'standalone', 'vite', evidence, ps, mode)
    end

    webpacker = gem?(gemfile, lock, 'webpacker') || safe_file?(repo, 'config/webpacker.yml')
    shakapacker = gem?(gemfile, lock, 'shakapacker') || safe_file?(repo, 'config/shakapacker.yml')
    webpack_files = config_files(repo, %w[webpack.config.js webpack.config.cjs webpack.config.mjs webpack.config.ts
                                          config/webpacker.yml config/shakapacker.yml bin/webpack-dev-server
                                          bin/shakapacker-dev-server bin/webpack])
    webpack_dep = has.call('webpack') || has.call('webpack-dev-server') || has.call('@rspack/core') || has.call('@rspack/cli')
    jsbundling = gem?(gemfile, lock, 'jsbundling-rails')
    webpack_jsbundling = jsbundling && (webpack_dep || script_matches?(scripts, /\bwebpack(?:\s|$)/))
    if webpacker || shakapacker || webpack_dep || !webpack_files.empty? || webpack_jsbundling
      bundler = has.call('@rspack/core') || has.call('@rspack/cli') ? 'rspack' : 'webpack'
      integration = if shakapacker then 'shakapacker'
                    elsif webpacker then 'webpacker'
                    elsif webpack_jsbundling then 'jsbundling-rails'
                    else 'standalone' end
      server_pattern = /(?:webpack-dev-server|shakapacker-dev-server|webpack\s+serve|rspack\s+serve)/
      watch_pattern = /(?:webpack|rspack).*(?:--watch|-w(?:\s|$))/
      dev_processes = process_matches(processes, scripts, server_pattern)
      watch_processes = process_matches(processes, scripts, watch_pattern)
      mode = if !dev_processes.empty? || script_matches?(scripts, server_pattern) then 'dev_server'
             elsif !watch_processes.empty? || script_matches?(scripts, watch_pattern) then 'watcher'
             else 'unknown' end
      evidence = webpack_files
      evidence << 'Gemfile.lock / Gemfile' if webpacker || shakapacker || webpack_jsbundling
      evidence << 'package.json' if webpack_dep
      evidence << 'Procfile.dev' unless (dev_processes + watch_processes).empty?
      detected << pipeline(integration, bundler, evidence, (dev_processes + watch_processes).uniq.sort, mode)
    end

    esbuild_files = config_files(repo, %w[esbuild.config.js esbuild.config.mjs esbuild.config.cjs esbuild.config.ts])
    esbuild_dep = has.call('esbuild') || has.call('esbuild-rails')
    if esbuild_dep || !esbuild_files.empty? || (jsbundling && script_matches?(scripts, /\besbuild\b/))
      js_processes = process_matches(processes, scripts, /\b(?:esbuild|build)(?:\s|$).*--watch/)
      # Rails jsbundling convention: js: yarn build --watch, where build executes esbuild.
      js_processes += processes.filter_map do |name, command|
        next unless command.match?(/(?:\bbuild\b.*--watch|--watch.*\bbuild\b)/)
        name if script_matches?(scripts, /\besbuild\b/)
      end
      mode = if !js_processes.empty? || script_matches?(scripts, /\besbuild\b.*--watch/) then 'watcher'
             elsif script_matches?(scripts, /\besbuild\b/) then 'build_only'
             else 'unknown' end
      evidence = esbuild_files
      evidence << 'package.json' if esbuild_dep || script_matches?(scripts, /\besbuild\b/)
      evidence << 'Gemfile.lock / Gemfile' if jsbundling
      evidence << 'Procfile.dev' unless js_processes.empty?
      detected << pipeline(jsbundling ? 'jsbundling-rails' : 'standalone', 'esbuild', evidence, js_processes.uniq.sort, mode)
    end

    if jsbundling && detected.none? { |p| p['integration'] == 'jsbundling-rails' }
      detected << pipeline('jsbundling-rails', 'unknown', ['Gemfile.lock / Gemfile'], [], 'unknown')
    end

    cssbundling = gem?(gemfile, lock, 'cssbundling-rails')
    tailwind_gem = gem?(gemfile, lock, 'tailwindcss-rails')
    css_deps = %w[tailwindcss sass postcss postcss-cli].select(&has)
    css_files = config_files(repo, %w[tailwind.config.js tailwind.config.cjs tailwind.config.ts postcss.config.js
                                      postcss.config.cjs postcss.config.mjs])
    if cssbundling || tailwind_gem || !css_deps.empty? || !css_files.empty?
      css_processes = process_matches(processes, scripts, /(?:\b(?:tailwindcss|sass|postcss)\b.*--watch|tailwindcss:watch|\bbuild:css\b.*--watch)/)
      css_processes += processes.keys.grep(/\Acss\z/) if processes['css']&.match?(/\b(?:build:css|tailwindcss:watch)\b/)
      mode = if !css_processes.empty? || script_matches?(scripts, /\b(?:tailwindcss|sass|postcss)\b.*--watch/) then 'watcher'
             else 'unknown' end
      evidence = css_files
      evidence << 'Gemfile.lock / Gemfile' if cssbundling || tailwind_gem
      evidence << 'package.json' unless css_deps.empty?
      evidence << 'Procfile.dev' unless css_processes.empty?
      detected << pipeline(cssbundling ? 'cssbundling-rails' : (tailwind_gem ? 'tailwindcss-rails' : 'standalone'),
                           css_deps.include?('tailwindcss') || tailwind_gem ? 'tailwindcss' : (css_deps.first || 'css'),
                           evidence, css_processes.uniq.sort, mode)
    end

    if gem?(gemfile, lock, 'importmap-rails') || safe_file?(repo, 'config/importmap.rb')
      evidence = []
      evidence << 'Gemfile.lock / Gemfile' if gem?(gemfile, lock, 'importmap-rails')
      evidence << 'config/importmap.rb' if safe_file?(repo, 'config/importmap.rb')
      detected << pipeline('importmap-rails', 'none', evidence, [], 'no_build')
    end

    if package_error
      notices << {
        'code' => 'frontend_package_metadata_invalid',
        'status' => 'ambiguous',
        'files' => ['package.json'],
        'message' => "Frontend inventory incomplete: #{package_error}. No package scripts were executed."
      }
    end
    unknown = detected.select { |p| p['mode'] == 'unknown' }
    unless unknown.empty?
      notices << {
        'code' => 'frontend_process_mode_unknown',
        'status' => 'ambiguous',
        'files' => unknown.flat_map { |p| p['evidence'] }.uniq.sort,
        'message' => 'Frontend tooling detected but no reliable dev server/watcher mode was found. Review bin/dev, Procfile.dev and package scripts.'
      }
    end
    watchers = detected.select { |p| p['mode'] == 'watcher' }
    unless watchers.empty?
      notices << {
        'code' => 'frontend_watcher_not_verified',
        'status' => 'detected_not_configured',
        'files' => watchers.flat_map { |p| p['evidence'] }.uniq.sort,
        'message' => 'Frontend build watcher detected, but Gitwo does not yet verify initial compilation or generated asset freshness. HMR is not required for this mode.'
      }
    end
    if detected.any? { |p| p['mode'] == 'dev_server' }
      notices << {
        'code' => 'frontend_hmr_not_verified',
        'status' => 'detected_not_configured',
        'files' => detected.select { |p| p['mode'] == 'dev_server' }.flat_map { |p| p['evidence'] }.uniq.sort,
        'message' => 'Frontend dev server detected, but Gitwo has not configured or verified asset URLs and WebSocket/HMR routing.'
      }
    end

    result = {
      'pipelines' => detected,
      'mode' => if detected.empty? then 'unknown'
                elsif detected.size == 1 then detected.first['mode']
                else 'mixed' end,
      'ambiguous' => !package_error.nil? || !unknown.empty?,
      'processes' => processes.keys.sort,
      'launcher' => safe_file?(repo, 'bin/dev') ? 'bin/dev' : (safe_file?(repo, 'Procfile.dev') ? 'Procfile.dev' : nil)
    }
    [result, notices]
  end
end
