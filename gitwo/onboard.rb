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
require_relative 'config-location'

class GitwoOnboard
  WORKFLOWS = %w[gitflow github-flow trunk-based gitlab-flow custom].freeze
  TRACKERS = %w[jira linear github none].freeze
  BOOTSTRAPS = %w[schema seeds].freeze
  MODES = %w[portless none].freeze
  BACKENDS = %w[native compose].freeze

  def initialize(action, argv)
    @action = action
    @options = { dry_run: false, yes: false, json: false, scope: 'local' }
    parser = OptionParser.new do |opt|
      opt.banner = "Usage: gitwo #{action} [--scope=local|team] [--project=PATH] [--output=PATH] [--yes|--dry-run|--json]"
      opt.on('--project=PATH', 'Select permanent Git checkout') { |v| @options[:project] = v }
      opt.on('--scope=SCOPE', 'Configuration scope: local (default) or team') { |v| @options[:scope] = v }
      opt.on('--config=PATH', 'Use a complete YAML configuration file') { |v| @options[:config] = v }
      opt.on('--output=PATH', 'Override config path (local mode only; stored outside the repo)') { |v| @options[:output] = v }
      opt.on('--yes', 'Non-interactive defaults and no credential prompts') { @options[:yes] = true }
      opt.on('--dry-run', 'Preview without writing any files') { @options[:dry_run] = true }
      opt.on('--json', 'Machine-readable detection or proposal') { @options[:json] = true }
      opt.on('-h', '--help', 'Display command help') { puts opt; exit 0 }
    end
    parser.parse!(argv)
    raise ArgumentError, "Unexpected arguments: #{argv.join(' ')}" unless argv.empty?
    raise ArgumentError, 'Scope must be local or team' unless %w[local team].include?(@options[:scope])
    raise ArgumentError, '--output applies only to init' if action == 'detect' && @options[:output]
    raise ArgumentError, '--scope applies only to init' if action == 'detect' && @options[:scope] != 'local'
    @script_dir = File.realpath(__dir__)
    @parent = File.realpath(File.join(@script_dir, '..'))
  end

  def run
    if @action == 'detect'
      project = GitwoProject.resolve(@script_dir, explicit: @options[:project],
                                    config_path: @options[:config])
      show_detection(GitwoDetection.detect(project))
      return
    end

    interactive = !$stdin.closed? && $stdin.tty? && !@options[:yes] &&
                  !@options[:dry_run] && !@options[:json]
    puts "Gitwo / init (scope: #{@options[:scope]})" if interactive
    suggested_project = begin
      GitwoProject.resolve(@script_dir, explicit: @options[:project])
    rescue ArgumentError
      File.expand_path(Dir.pwd)
    end
    selected_project = if interactive && !@options[:project]
                         ask_path('Project checkout', suggested_project)
                       else
                         @options[:project] || suggested_project
                       end
    project = GitwoProject.resolve(@script_dir, explicit: selected_project)
    locations = GitwoConfigLocation.paths(project)
    scope = @options[:scope]
    default_output = scope == 'team' ? locations[:team] : GitwoConfigLocation.local(project)
    raise ArgumentError, '--output is not supported with --scope=team (uses repo/gitwo.yml)' if
      scope == 'team' && @options[:output] && File.expand_path(@options[:output]) != locations[:team]
    output = @options[:output] ? File.expand_path(@options[:output]) : default_output
    output = ask_path('Configuration file', output) if interactive && !@options[:output]
    if scope == 'team'
      raise ArgumentError, 'Team config must be the project-root gitwo.yml' unless output == locations[:team]
    else
      output = GitwoConfigLocation.validate_local_target(project, output)
    end

    explicit = @options[:config] && File.expand_path(@options[:config])
    existing = explicit || (File.exist?(output) || File.symlink?(output) ? output : nil)
    detection = GitwoDetection.detect(project)

    if existing
      validated = load_and_validate(existing)
      if @options[:dry_run] || @options[:json]
        if @options[:json]
          puts JSON.pretty_generate(status: 'existing', scope: scope, project: project,
                                    source: existing, config_path: output,
                                    proposed_config: validated, detection: detection)
        else
          puts "Scope: #{scope}\nProject: #{project}\nConfig: #{output}"
          puts "Existing configuration: #{existing}\nNo changes required."
        end
        return
      end
      if File.expand_path(existing) != output
        raise ArgumentError, "Target config already exists: #{output}" if
          File.exist?(output) || File.symlink?(output)
        write_config(output, File.read(existing), scope)
        puts "[OK] Configuration copied to #{output}"
      else
        puts "[OK] Existing configuration validated: #{existing}"
      end
      activate_location(project, scope, output)
      puts "[INFO] Active scope: #{scope}; project: #{project}"
      display_environment_notices(detection)
      display_selected_backend_notice(validated.dig('services', 'backend'))
      return
    end

    suggested = detection.fetch('suggested')
    if @options[:dry_run] || @options[:json]
      show_proposal(suggested, detection, project, output, scope)
      return
    end

    unless @options[:yes] || interactive
      raise ArgumentError, 'Interactive input needs a TTY. Use --yes or supply --project=PATH.'
    end
    if interactive
      display_findings(detection)
      suggested['git']['workflow'] = choose('Git workflow', WORKFLOWS, suggested.dig('git', 'workflow'))
      suggested['issues']['provider'] = choose('Issue tracker', TRACKERS, 'none')
      if %w[jira linear].include?(suggested.dig('issues', 'provider'))
        suggested['issues']['credential'] = ask('Credential profile (letters, digits, - and _)', 'default')
      end
      suggested['services']['backend'] = choose('PostgreSQL/Redis service backend (Gitwo-managed Compose)', BACKENDS, 'native')
      display_selected_backend_notice(suggested.dig('services', 'backend'))
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
      puts "\nScope: #{scope}\nProject: #{project}\nConfiguration: #{output}"
      puts "Changes in Rails repository: #{scope == 'local' ? 'none' : 'new untracked gitwo.yml'}"
      puts "\nReview proposed configuration:\n#{YAML.dump(suggested)}"
      raise ArgumentError, 'Cancelled without writing' unless ask('Save configuration? [y/N]', 'n').downcase == 'y'
    else
      puts "[INFO] Non-interactive init: scope=#{scope}, project=#{project}, output=#{output}"
      display_environment_notices(detection)
      display_selected_backend_notice(suggested.dig('services', 'backend'))
      unless detection.dig('detected', 'framework', 'value') == 'rails'
        raise ArgumentError, 'Cannot safely initialize a non-Rails repository with --yes'
      end
    end

    validate_refs(project, suggested)
    write_config(output, YAML.dump(suggested), scope)
    activate_location(project, scope, output)
    puts "[OK] Configuration saved: #{output}"
    puts "[INFO] Active scope: #{scope}; project: #{project}"
    puts '[INFO] No Git commits, pushes or Rails database changes were performed.'
    if scope == 'team'
      puts '[INFO] Review gitwo.yml before choosing to commit it for the team.'
    end
    if suggested.dig('issues', 'provider') == 'jira' && interactive
      credential_setup(suggested.dig('issues', 'url'), suggested.dig('issues', 'credential') || 'default')
    elsif suggested.dig('issues', 'provider') != 'jira'
      credential_setup_linear(suggested.dig('issues', 'credential') || 'default') if
        suggested.dig('issues', 'provider') == 'linear' && interactive
      puts '[INFO] GitHub uses gh auth login for authentication.' if suggested.dig('issues', 'provider') == 'github'
    end
    puts '[INFO] Run gitwo doctor and gitwo config validate before creating workspaces.'
  end

  def ask_path(label, default)
    color = $stdout.tty? && !ENV.key?('NO_COLOR') && ENV.fetch('TERM', '') != 'dumb'
    hint = color ? "\e[2m#{default}\e[0m" : default
    print "#{label} [#{hint}]: "
    entered = $stdin.gets
    raise ArgumentError, 'Input ended before confirmation' if entered.nil?
    entered = entered.strip
    entered.empty? ? default : File.expand_path(entered)
  end

  def activate_location(project, scope, output)
    GitwoConfigLocation.register(project, output) if scope == 'local'
    GitwoConfigLocation.use(project, scope)
  end

  def write_config(path, contents, scope)
    GitwoConfigLocation.prepare_directory(File.dirname(path)) if scope == 'local'
    safe_write(path, contents)
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
    display_environment_notices(detection)
  end

  def display_environment_notices(detection)
    detection.fetch('notices', []).each do |notice|
      warn "  [NOTICE] #{notice.fetch('message')} Detected: #{notice.fetch('files').join(', ')}"
    end
  end

  def display_selected_backend_notice(backend)
    return unless backend == 'compose'

    warn '  [NOTICE] Gitwo-managed Compose selected: isolated PostgreSQL/Redis only. Existing application Compose files and Dev Containers are NOT configured to launch.'
  end

  def show_proposal(suggested, detection, project, output, scope)
    if @options[:json]
      puts JSON.pretty_generate({ scope: scope, project: project, config_path: output,
                                  proposed_config: suggested, detection: detection, would_write: output })
    else
      puts "Scope: #{scope}\nProject: #{project}\nConfiguration: #{output}"
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
      prefix = ref.start_with?('origin/') ? 'refs/remotes/' : 'refs/heads/'
      unless GitwoProject.git('-C', repo, 'show-ref', '--verify', "#{prefix}#{ref}")
        raise ArgumentError, "Required Git base ref does not exist: #{ref}. Fetch origin or select an existing local branch."
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
