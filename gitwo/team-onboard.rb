#!/usr/bin/env ruby
# Adopt an existing team gitwo.yml without reinitializing or changing project files.
# --check is intentionally repository-only and safe for CI / shallow clones.
require 'json'
require 'yaml'
require 'optparse'
require 'open3'
require 'rbconfig'
require_relative 'project'
require_relative 'config-location'

class GitwoTeamOnboard
  def initialize(argv)
    @options = { check: false, local: false, json: false, setup: false, yes: false, scope: 'local' }
    parser = OptionParser.new do |options|
      options.banner = 'Usage: gitwo onboard [--scope=local|team] [--check] [--local] [--json] [--setup [--yes]] [--project=PATH]'
      options.on('--scope=SCOPE', 'Configuration scope: local (default) or team') { |value| @options[:scope] = value }
      options.on('--check', 'Validate the selected config without changing anything (CI mode)') { @options[:check] = true }
      options.on('--local', 'Also check developer toolchain and local credentials') { @options[:local] = true }
      options.on('--json', 'Output machine-readable checks, without secrets') { @options[:json] = true }
      options.on('--setup', 'Opt in to a new schema-only develop workspace') { @options[:setup] = true }
      options.on('--yes', 'Confirm explicit --setup in a noninteractive session') { @options[:yes] = true }
      options.on('--project=PATH', 'Select a specific primary checkout') { |path| @options[:project] = path }
      options.on('-h', '--help', 'Show help') { puts options; exit 0 }
    end
    parser.parse!(argv)
    raise ArgumentError, "Unexpected arguments: #{argv.join(" ")}" unless argv.empty?
    raise ArgumentError, 'Scope must be local or team' unless %w[local team].include?(@options[:scope])
    raise ArgumentError, '--setup cannot be combined with --check or --json' if @options[:setup] && (@options[:check] || @options[:json])
    raise ArgumentError, '--yes is valid only with --setup' if @options[:yes] && !@options[:setup]
    @options[:local] = true unless @options[:check]
    @checks = []
  end

  def run
    interactive = $stdin.tty? && !@options[:yes] && !@options[:check] && !@options[:json]
    default_project = begin
      GitwoProject.resolve(nil, explicit: @options[:project])
    rescue ArgumentError
      File.expand_path(Dir.pwd)
    end
    chosen = if interactive && !@options[:project]
               $stdout.print "Project checkout [#{default_project}]: "
               answer = $stdin.gets
               raise ArgumentError, 'No project path supplied' if answer.nil?
               answer.strip.empty? ? default_project : File.expand_path(answer.strip)
             else
               @options[:project] || default_project
             end
    @project = GitwoProject.resolve(nil, explicit: chosen)
    @config_path = if @options[:scope] == 'team'
                     GitwoConfigLocation.paths(@project)[:team]
                   else
                     GitwoConfigLocation.local(@project)
                   end
    unless File.file?(@config_path) && !File.symlink?(@config_path)
      next_step = @options[:scope] == 'team' ?
        'A maintainer must run gitwo init --scope=team, review and commit gitwo.yml.' :
        'Run gitwo init --scope=local to create a private config outside the repository.'
      record('scoped_config', false, "Missing or unsafe #{@options[:scope]} configuration. #{next_step}")
      return finish
    end
    record('scoped_config', true, "Regular #{@options[:scope]} configuration found")

    if @options[:scope] == 'team'
      unless git_success?('cat-file', '-e', 'HEAD:gitwo.yml') &&
             git_success?('ls-files', '--error-unmatch', '--', 'gitwo.yml')
        record('committed_config', false, 'Team gitwo.yml must be committed in HEAD and tracked in the index')
        return finish
      end
      record('committed_config', true, 'Team configuration committed in HEAD')
    end

    _output, _errors, status = Open3.capture3(RbConfig.ruby, File.join(__dir__, 'config.rb'), 'validate', @config_path)
    unless status.success?
      record('schema', false, 'gitwo.yml failed strict schema validation; run gitwo config validate')
      return finish
    end
    @config = safe_load(@config_path)
    record('schema', true, 'Strict schema version 1 validated; no YAML code or aliases evaluated')
    name = @config.fetch('project', {}).fetch('source', File.basename(@project))
    record('checkout_name', true, name == File.basename(@project) ?
      'Shared project name matches this checkout' :
      'Checkout directory differs from team project name; per-machine paths use the local checkout')

    # These checks are CI-safe and must not require local Docker, credentials, or a database.
    if @options[:local]
      local_checks
      database_integration
    end
    if !@options[:check] && !@options[:json] && !failed?
      GitwoConfigLocation.use(@project, @options[:scope])
    end
    return finish unless @options[:setup]

    if failed?
      warn 'gitwo onboard: local prerequisites must pass before --setup'
      return finish
    end
    unless @config.dig('project', 'adapter') == 'rails-standard'
      record('setup_adapter', false, 'Automatic onboarding requires the rails-standard adapter; configure other adapters manually')
      return finish
    end
    unless @db_integrated
      record('setup_database', false, 'Review and commit gitwo workspace env integrate --dry-run / --apply before --setup')
      return finish
    end
    unless @options[:yes]
      raise ArgumentError, '--setup needs an interactive terminal or explicit --yes' unless $stdin.tty?
      $stderr.print 'Create a new local develop workspace and schema-only PostgreSQL DBs? Type setup: '
      raise ArgumentError, 'Setup cancelled; nothing created' unless $stdin.gets&.strip == 'setup'
    end
    puts 'Creating a new develop workspace using the committed team configuration (no seeds).'
    # Intentionally delegate all locks, safe DB creation and direnv activation to Gitwo.
    env = { 'GITWO_PROJECT_ROOT' => @project,
            'GITWO_SCOPE' => @options[:scope], 'GITWO_CONFIG_FILE' => @config_path }
    ok = system(env, File.join(__dir__, 'new.sh'), 'develop', '--no-seed', chdir: @project)
    raise ArgumentError, 'Workspace setup did not finish. Existing partial workspaces are preserved; inspect Gitwo logs before retrying.' unless ok
    puts 'Next: review the generated .envrc inside the workspace and run direnv allow .'
    finish
  rescue ArgumentError, SystemCallError, Psych::Exception => error
    warn "gitwo onboard: #{error.message}"
    2
  end

  private

  def safe_load(path)
    data = File.binread(path)
    if Psych::VERSION.split('.').first.to_i >= 4
      YAML.safe_load(data, permitted_classes: [], permitted_symbols: [], aliases: false)
    else
      YAML.safe_load(data, [], [], false)
    end
  end

  def git_success?(*args)
    _out, _err, status = Open3.capture3('git', '-C', @project, *args)
    status.success?
  end

  def record(id, ok, message, severity: 'error')
    @checks << { id: id, status: ok ? 'ok' : (severity == 'warning' ? 'warning' : 'missing'), message: message }
  end

  def failed?
    @checks.any? { |check| check[:status] == 'missing' }
  end

  def executable?(name)
    ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).any? do |directory|
      path = File.join(directory.empty? ? '.' : directory, name)
      File.file?(path) && File.executable?(path)
    end
  end

  def dependency(name, why)
    available = executable?(name)
    record("tool_#{name}", available, available ? "#{name} available" : "Install #{name} (#{why})")
  end

  def local_checks
    %w[git ruby mise psql createdb pg_dump pg_restore lsof direnv].each do |tool|
      dependency(tool, 'required for local Rails workspaces')
    end
    backend = @config.fetch('services', {}).fetch('backend', 'native')
    if backend == 'compose'
      dependency('docker', 'managed Compose services')
      if executable?('docker')
        record('docker_compose', command_ok?('docker', 'compose', 'version'),
          'Docker Compose V2 must be available')
        record('docker_daemon', command_ok?('docker', 'info'),
          'Docker daemon must be running')
      end
    else
      %w[redis-server redis-cli].each { |tool| dependency(tool, 'native Redis services') }
    end
    if @config.fetch('runtime', {}).fetch('proxy', 'none') == 'portless'
      dependency('node', 'Portless HTTPS')
      if executable?('node')
        record('node_version', command_ok?('node', '-e', 'process.exit(Number(process.versions.node.split(".")[0]) >= 24 ? 0 : 1)'),
          'Portless requires Node.js 24+')
      end
      dependency('portless', 'Portless HTTPS')
    end
    issue_provider_checks
  end

  def command_ok?(*command)
    _out, _err, status = Open3.capture3(*command)
    status.success?
  rescue SystemCallError
    false
  end

  def issue_provider_checks
    issues = @config.fetch('issues', {})
    provider = issues.fetch('provider', 'none')
    profile = issues.fetch('credential', 'default')
    if provider == 'github'
      dependency('gh', 'GitHub Issues provider')
      record('github_auth', command_ok?('gh', 'auth', 'status'),
        'Authenticate locally with gh auth login', severity: 'warning') if executable?('gh')
    elsif %w[jira linear].include?(provider)
      return if (provider == 'jira' && (ENV.key?('JIRA_API_TOKEN') || ENV.key?('JIRA_BEARER_TOKEN'))) ||
                (provider == 'linear' && ENV.key?('LINEAR_API_KEY'))
      root = File.join(ENV.fetch('XDG_CONFIG_HOME', File.join(Dir.home, '.config')), 'gitwo')
      file = File.join(root, 'credentials', profile, "#{provider}.env")
      legacy = File.join(root, "#{provider}.env")
      file = legacy if profile == 'default' && !File.exist?(file) && !File.symlink?(file)
      if File.exist?(file) || File.symlink?(file)
        safe = File.file?(file) && !File.symlink?(file) &&
               File.stat(file).uid == Process.uid && (File.stat(file).mode & 0o077).zero?
        record('provider_credentials', safe, safe ? 'Private provider credentials file available' :
          'Provider credentials must be a regular owner-only file (mode 0600)')
      else
        record('provider_credentials', false,
          "Add private #{provider} credentials under ~/.config/gitwo/credentials/#{profile}/ (never commit secrets)",
          severity: 'warning')
      end
    end
  end

  def database_integration
    file = File.join(@project, 'config', 'database.yml')
    unless File.file?(file) && !File.symlink?(file)
      record('database_integration', false, 'No regular config/database.yml; verify Rails database configuration', severity: 'warning')
      @db_integrated = false
      return
    end
    body = File.read(file)
    @db_integrated = body.include?('GITWO_DB_DEV') && body.include?('GITWO_DB_TEST')
    record('database_integration', @db_integrated,
      @db_integrated ? 'Workspace database markers present (effective Rails connection still verified at setup)' :
      'Tracked database.yml is not Gitwo-aware; preview gitwo workspace env integrate --dry-run',
      severity: 'warning')
  end

  def finish
    ready = !failed?
    if @options[:json]
      puts JSON.pretty_generate({
        status: ready ? 'ok' : 'failed',
        mode: @options[:check] ? (@options[:local] ? 'check-local' : 'check') : 'onboard',
        scope: @options[:scope],
        project: @project,
        config: @config_path,
        checks: @checks
      })
    else
      puts "Gitwo #{@options[:scope]} onboarding for #{@project}"
      @checks.each do |check|
        marker = { 'ok' => 'OK', 'warning' => 'WARN', 'missing' => 'FAIL' }.fetch(check[:status])
        puts "  [#{marker}] #{check[:id]}: #{check[:message]}"
      end
      if ready && !@options[:check] && !@options[:setup]
        puts "Configuration accepted (#{@options[:scope]} scope). Next: gitwo new develop --no-setup"
        puts 'Or explicitly run gitwo onboard --setup after reviewing the database configuration.'
      end
    end
    ready ? 0 : 1
  end
end

exit GitwoTeamOnboard.new(ARGV).run
