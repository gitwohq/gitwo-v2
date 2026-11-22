#!/usr/bin/env ruby
# Interactive/offline project onboarding. Never writes to an application database.
require 'json'
require 'yaml'
require 'optparse'
require 'open3'
require 'fileutils'
require 'tempfile'
require 'io/console'
require_relative 'detect'
require_relative 'project'

class GitwoOnboard
  WORKFLOWS = %w[gitflow github-flow trunk-based gitlab-flow custom].freeze
  TRACKERS = %w[jira linear github none].freeze
  BOOTSTRAPS = %w[schema seeds].freeze
  MODES = %w[portless none].freeze
  BACKENDS = %w[native compose].freeze

  def initialize(action, argv)
    @action = action
    @options = { dry_run: false, yes: false, json: false }
    parser = OptionParser.new do |opt|
      opt.banner = "Usage: gitwo #{action} [--project=PATH] [--config=PATH] [--json|--yes|--dry-run]"
      opt.on('--project=PATH', 'Select permanent Git checkout') { |v| @options[:project] = v }
      opt.on('--config=PATH', 'Use a complete YAML configuration file') { |v| @options[:config] = v }
      opt.on('--output=PATH', 'Where to write generated config (default: Gitwo config.yml)') { |v| @options[:output] = v }
      opt.on('--yes', 'Non-interactive defaults and no credential prompts') { @options[:yes] = true }
      opt.on('--dry-run', 'Preview without writing any files') { @options[:dry_run] = true }
      opt.on('--json', 'Machine-readable detection or proposal') { @options[:json] = true }
      opt.on('-h', '--help', 'Display command help') { puts opt; exit 0 }
    end
    parser.parse!(argv)
    raise ArgumentError, "Unexpected arguments: #{argv.join(' ')}" unless argv.empty?
    raise ArgumentError, '--output applies only to init' if action == 'detect' && @options[:output]
    @script_dir = File.realpath(__dir__)
    @parent = File.realpath(File.join(@script_dir, '..'))
  end

  def run
    explicit = @options[:config] && File.expand_path(@options[:config])
    project = GitwoProject.resolve(@script_dir, explicit: @options[:project], config_path: explicit)
    repo_yaml = File.join(project, 'gitwo.yml')
    existing = explicit || (File.expand_path(ENV['GITWO_CONFIG_FILE']) if ENV['GITWO_CONFIG_FILE'])
    existing ||= repo_yaml if File.exist?(repo_yaml) || File.symlink?(repo_yaml)
    detection = GitwoDetection.detect(project)
    if @action == 'detect'
      show_detection(detection)
      return
    end
    if existing
      validated = load_and_validate(existing)
      # project.source is a shared logical label; each developer may choose a
      # different clone directory without rewriting the team configuration.
      if @options[:dry_run] || @options[:json]
        puts @options[:json] ? JSON.pretty_generate({ status: 'existing', source: existing, proposed_config: validated, detection: detection }) : "Existing configuration: #{existing}\nNo changes required."
        return
      end
      output = File.expand_path(@options.fetch(:output, repo_yaml))
      if File.realpath(existing) == output
        puts "[OK] Existing configuration validated: #{existing}"
        puts "[INFO] Detected framework: #{detection.dig('detected', 'framework', 'value')}; workflow: #{detection.dig('inferred', 'workflow', 'value')}"
        return
      end
      if (File.exist?(output) || File.symlink?(output)) && !@options[:output]
        puts "[INFO] An active local config already exists: #{output}"
        puts "[INFO] Kept it unchanged. To use the selected file: export GITWO_CONFIG_FILE=#{existing}"
        return
      end
      safe_write(output, File.read(existing))
      puts "[OK] Existing configuration copied to #{output}"
      return
    end

    suggested = detection.fetch('suggested')
    if @options[:dry_run]
      show_proposal(suggested, detection)
      return
    end
    unless @options[:yes] || $stdin.tty?
      raise ArgumentError, 'Interactive input needs a TTY. Use --yes or supply --config=PATH.'
    end
    unless @options[:yes]
      display_findings(detection)
      suggested['git']['workflow'] = choose('Git workflow', WORKFLOWS, suggested.dig('git', 'workflow'))
      suggested['issues']['provider'] = choose('Issue tracker', TRACKERS, 'none')
      if %w[jira linear].include?(suggested.dig('issues', 'provider'))
        suggested['issues']['credential'] = ask('Credential profile (letters, digits, - and _)', 'default')
      end
      suggested['services']['backend'] = choose('PostgreSQL/Redis service backend (Gitwo-managed Compose)', BACKENDS, 'native')
      suggested['database']['bootstrap'] = choose('New database bootstrap (seeds may have side effects)', BOOTSTRAPS, 'schema')
      suggested['runtime']['proxy'] = choose('HTTP proxy', MODES, suggested.dig('runtime', 'proxy'))
      case suggested.dig('issues', 'provider')
      when 'jira'
        suggested['issues']['url'] = ask('Jira site URL (e.g. https://team.atlassian.net)', '')
        suggested['issues'].delete('url') if suggested['issues']['url'].empty?
      when 'github'
        suggested['issues']['url'] = ask('GitHub repository URL (optional, detected from origin)', '')
        suggested['issues'].delete('url') if suggested['issues']['url'].empty?
      end
      puts '\nReview proposed configuration:'
      puts YAML.dump(suggested)
      raise ArgumentError, 'Cancelled without writing' unless ask('Save configuration? [y/N]', 'n').downcase == 'y'
    else
      puts '[INFO] Non-interactive mode: no network calls, no credentials, no Rails side effects' unless @options[:json]
      unless detection.dig('detected', 'framework', 'value') == 'rails'
        raise ArgumentError, 'Cannot safely initialize a non-Rails repository with --yes (Rails-only adapters currently)'
      end
    end

    # No destructive initialization if Git refs are missing.
    validate_refs(project, suggested)
    contents = YAML.dump(suggested)
    output = File.expand_path(@options.fetch(:output, repo_yaml))
    safe_write(output, contents)
    puts "[OK] Configuration saved: #{output}"
    puts "[INFO] Project: #{project}"
    if output != repo_yaml
      puts "[INFO] Activate with: export GITWO_CONFIG_FILE=#{output}"
    end
    if suggested.dig('issues', 'provider') == 'jira' && !@options[:yes]
      credential_setup(suggested.dig('issues', 'url'), suggested.dig('issues', 'credential') || 'default')
    elsif suggested.dig('issues', 'provider') != 'jira'
      credential_setup_linear(suggested.dig('issues', 'credential') || 'default') if suggested.dig('issues', 'provider') == 'linear' && !@options[:yes]
      puts '[INFO] GitHub uses gh auth login for authentication.' if suggested.dig('issues', 'provider') == 'github'
    end
    puts '[INFO] Run gitwo doctor and gitwo config validate before creating workspaces.'
  end

  private

  def active_config
    candidates = [ENV['GITWO_CONFIG_FILE'], repo_yaml].compact
    candidates.find { |p| File.exist?(p) || File.symlink?(p) }&.then { |p| File.expand_path(p) }
  end

  def show_detection(detection)
    if @options[:json]
      puts JSON.pretty_generate(detection)
    else
      display_findings(detection)
    end
  end

  def display_findings(detection)
    puts "gitwo / project detection\n  Repository: #{detection['repository']}"
    detection.fetch('detected').each do |key, entry|
      puts "  #{key.ljust(16)} #{entry['value'].inspect.ljust(15)} [#{entry['confidence']}] #{entry['source']}"
    end
    inferred = detection.dig('inferred', 'workflow')
    puts "  #{'git workflow'.ljust(16)} #{inferred['value'].inspect.ljust(15)} [#{inferred['confidence']}] #{inferred['source']}"
    detection['warnings'].each { |warning| warn "  [WARN] #{warning}" }
  end

  def show_proposal(suggested, detection)
    if @options[:json]
      puts JSON.pretty_generate({ proposed_config: suggested, detection: detection, would_write: @options.fetch(:output, repo_yaml) })
    else
      display_findings(detection)
      puts "\nProposed config (not written):\n#{YAML.dump(suggested)}"
    end
  end

  def choose(title, options, default)
    puts "\n#{title}:"
    options.each_with_index { |name, index| puts "  #{index + 1}) #{name}#{name == default ? ' [suggested]' : ''}" }
    answer = ask('Select number or value', default)
    chosen = if answer.match?(/\A[1-9]\d*\z/)
               options[answer.to_i - 1]
             else
               answer
             end
    raise ArgumentError, "Unsupported choice: #{answer}" unless options.include?(chosen)
    chosen
  end

  def ask(label, default)
    print "#{label}#{default.to_s.empty? ? '' : " [#{default}]"}: "
    input = $stdin.gets
    raise ArgumentError, 'Input ended before confirmation' if input.nil?
    input = input.strip
    input.empty? ? default : input
  end

  def load_and_validate(path)
    raise ArgumentError, "Unsafe configuration file: #{path}" unless File.file?(path) && !File.symlink?(path)
    _stdout, stderr, status = Open3.capture3(RbConfig.ruby, File.join(@script_dir, 'config.rb'), 'validate', path)
    raise ArgumentError, "Invalid configuration: #{stderr.strip}" unless status.success?
    YAML.safe_load_file(path, permitted_classes: [], permitted_symbols: [], aliases: false)
  end

  def validate_refs(repo, suggested)
    %w[feature_base hotfix_base].each do |key|
      ref = suggested.fetch('branches').fetch(key)
      unless GitwoProject.git('-C', repo, 'show-ref', '--verify', "refs/remotes/#{ref}") != nil
        raise ArgumentError, "Required remote branch does not exist: #{ref}. Fetch origin or select a different workflow."
      end
    end
  end

  def safe_write(path, contents)
    raise ArgumentError, "Refusing to overwrite existing configuration: #{path}" if File.exist?(path) || File.symlink?(path)
    directory = File.dirname(path)
    raise ArgumentError, "Output directory does not exist: #{directory}" unless File.directory?(directory) && !File.symlink?(directory)
    # Validate the exact output bytes, including any --config copy, before creating the final file.
    Tempfile.create(['gitwo-proposal-', '.yml'], directory) do |tmp|
      tmp.write(contents)
      tmp.flush
      load_and_validate(tmp.path)
      # Atomic publish without overwriting existing configs or leaving partial files.
      File.link(tmp.path, path)
    end
  end

  def credential_setup_linear(profile)
    return unless ask('Configure Linear API key now? [y/N]', 'n').downcase == 'y'
    token = IO.console&.getpass('Linear API key (hidden): ')
    raise ArgumentError, 'Invalid Linear API key' if token.to_s.empty? || token.match?(/\s/)
    directory = File.join(ENV.fetch('XDG_CONFIG_HOME', File.join(Dir.home, '.config')), 'gitwo', 'credentials', profile)
    FileUtils.mkdir_p(directory, mode: 0o700)
    path = File.join(directory, 'linear.env')
    File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write("LINEAR_API_KEY=#{token}\n") }
    puts "[OK] Private Linear credentials saved to #{path}"
  ensure
    token = nil
  end

  def credential_setup(url, profile)
    puts '\nJira credentials are stored separately from project YAML.'
    answer = ask('Configure Jira credentials now? [y/N]', 'n')
    return unless answer.downcase == 'y'
    base = url || ask('Jira site URL', '')
    raise ArgumentError, 'Jira URL must be HTTPS' unless base.match?(%r{\Ahttps://[A-Za-z0-9.-]+(?:/[A-Za-z0-9._/-]*)?\z})
    email = ask('Jira account email', '')
    raise ArgumentError, 'Invalid Jira account email' unless email.match?(/\A[^\s=@]+@[^\s=@]+\z/)
    token = IO.console&.getpass('Jira API token (hidden): ')
    raise ArgumentError, 'Jira token is empty or contains whitespace' if token.to_s.empty? || token.match?(/\s/)
    path = File.join(ENV.fetch('XDG_CONFIG_HOME', File.join(Dir.home, '.config')), 'gitwo', 'credentials', profile, 'jira.env')
    raise ArgumentError, "Credential file already exists: #{path}; will not overwrite" if File.exist?(path) || File.symlink?(path)
    FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
    File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
      file.write("JIRA_BASE_URL=#{base}\nJIRA_EMAIL=#{email}\nJIRA_API_TOKEN=#{token}\n")
    end
    puts "[OK] Private Jira credentials saved to #{path}"
  ensure
    token = nil
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    action = ARGV.shift
    raise ArgumentError, 'Usage: onboard.rb <init|detect> [options]' unless %w[init detect].include?(action)
    GitwoOnboard.new(action, ARGV).run
  rescue ArgumentError, OptionParser::ParseError, SystemCallError, Psych::Exception => e
    warn "gitwo: #{e.message}"
    exit 2
  end
end
