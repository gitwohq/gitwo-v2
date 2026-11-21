#!/usr/bin/env ruby
# Inspect a local repository without evaluating application code or changing files.
require 'json'
require 'pathname'
require 'open3'

module GitwoDetection
  module_function

  def git(directory, *args)
    output, status = Open3.capture2('git', '-C', directory, *args, err: File::NULL)
    status.success? ? output.strip : nil
  rescue Errno::ENOENT
    nil
  end

  def text(path, limit = 1_000_000)
    return '' unless File.file?(path) && !File.symlink?(path) && File.size(path) <= limit
    File.read(path, encoding: 'UTF-8').scrub
  rescue SystemCallError
    ''
  end

  def observed(value, source, confidence)
    { 'value' => value, 'source' => source, 'confidence' => confidence }
  end

  def detect(repo)
    repo = File.realpath(repo)
    root = git(repo, 'rev-parse', '--show-toplevel')
    raise ArgumentError, "Not a Git checkout: #{repo}" unless root == repo
    name = File.basename(root)
    raise ArgumentError, 'Unsafe checkout directory name' unless name.match?(/\A[A-Za-z][A-Za-z0-9_-]*\z/)

    refs = git(repo, 'for-each-ref', '--format=%(refname:short)', 'refs/heads', 'refs/remotes')&.lines&.map(&:strip) || []
    remote = git(repo, 'remote', 'get-url', 'origin').to_s
    head = git(repo, 'symbolic-ref', '--short', 'refs/remotes/origin/HEAD')
    main = if head&.start_with?('origin/')
             head.delete_prefix('origin/')
           else
             %w[main master trunk].find { |branch| refs.include?(branch) || refs.include?("origin/#{branch}") }
           end
    current = git(repo, 'branch', '--show-current')
    main ||= current if current && !current.empty?
    branches = refs.map { |ref| ref.delete_prefix('origin/') }
    develop = branches.include?('develop')
    if develop && %w[main master].include?(main)
      workflow = observed('gitflow', 'main/master + develop refs', 'medium')
      feature_base = 'origin/develop'
      hotfix_base = "origin/#{main}"
      base_branch = current == 'develop' ? 'develop' : main
    else
      has_features = branches.any? { |branch| branch.start_with?('feature/', 'fix/') }
      workflow = observed('github-flow', has_features ? 'primary + feature refs' : 'primary branch (fallback)', has_features ? 'medium' : 'low')
      feature_base = "origin/#{main}"
      hotfix_base = feature_base
      base_branch = main
    end
    main_ref = "origin/#{main}"
    if main.nil? || !refs.include?(main_ref)
      workflow['confidence'] = 'low'
    end

    gemfile = text(File.join(repo, 'Gemfile'))
    lock = text(File.join(repo, 'Gemfile.lock'))
    db_config = text(File.join(repo, 'config/database.yml'))
    rails_markers = File.file?(File.join(repo, 'config/application.rb')) && (gemfile.match?(/\bgem\s*['\"]rails['\"]/) || lock.match?(/^    rails \(/))
    rails = observed(rails_markers ? 'rails' : 'unknown', rails_markers ? 'Gemfile + config/application.rb' : 'no Rails markers', rails_markers ? 'high' : 'low')
    postgres = gemfile.match?(/\bgem\s*['\"]pg['\"]/) || db_config.match?(/adapter:\s*postgresql/) || lock.match?(/^    pg \(/)
    sidekiq = gemfile.match?(/\bgem\s*['\"]sidekiq['\"]/) || lock.match?(/^    sidekiq \(/) || File.file?(File.join(repo, 'config/sidekiq.yml'))
    redis = sidekiq || gemfile.match?(/\bgem\s*['\"]redis['\"]/) || lock.match?(/^    redis \(/) || File.file?(File.join(repo, 'config/redis.yml'))
    seed_file = File.file?(File.join(repo, 'db/seeds.rb'))
    ruby_version = text(File.join(repo, '.ruby-version')).strip
    ruby_version = nil unless ruby_version.match?(/\A\d+\.\d+\.\d+\z/)
    git_provider = if remote.include?('github.com') then 'github'
                   elsif remote.include?('gitlab') then 'gitlab'
                   else 'unknown' end
    default_issues = 'none'
    issue_hint = if refs.any? { |ref| ref.match?(/[A-Z][A-Z0-9]+-\d+/) }
                   'ticket-like branch names (provider uncertain)'
                 else
                   'no issue tracker configuration detected'
                 end
    proxy = if system('sh', '-c', 'command -v portless >/dev/null 2>&1', out: File::NULL, err: File::NULL)
              'portless'
            else
              'none'
            end
    db_user = ENV.fetch('PGUSER', ENV.fetch('USER', 'postgres'))
    db_user = 'postgres' unless db_user.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
    prefix = name.downcase.gsub(/[^a-z0-9_]/, '_').gsub(/_+/, '_')[0, 20]
    prefix = "app_#{prefix}" unless prefix.match?(/\A[a-z]/)
    prefix = prefix[0, 20]
    domain = name.downcase.gsub(/[^a-z0-9-]/, '-').gsub(/-+/, '-').sub(/\A-/, '').sub(/-\z/, '')
    domain = 'app' unless domain.match?(/\A[a-z][a-z0-9]*(?:-[a-z0-9]+)*\z/) && domain.length <= 63
    {
      'repository' => root,
      'detected' => {
        'framework' => rails,
        'database' => observed(postgres ? 'postgresql' : 'unknown', postgres ? 'Gemfile.lock / config/database.yml' : 'no PostgreSQL markers', postgres ? 'high' : 'low'),
        'sidekiq' => observed(!!sidekiq, sidekiq ? 'Gemfile.lock / config/sidekiq.yml' : 'not detected', sidekiq ? 'high' : 'low'),
        'redis' => observed(!!redis, redis ? 'Gemfile.lock / Sidekiq / config' : 'not detected', redis ? 'medium' : 'low'),
        'seeds' => observed(seed_file, seed_file ? 'db/seeds.rb' : 'not detected', seed_file ? 'high' : 'low'),
        'ruby_version' => observed(ruby_version, ruby_version ? '.ruby-version' : 'not detected', ruby_version ? 'high' : 'low'),
        'git_provider' => observed(git_provider, remote.empty? ? 'no origin remote' : 'origin remote URL', remote.empty? ? 'low' : 'high'),
        'issues' => observed(default_issues, issue_hint, 'low')
      },
      'inferred' => { 'workflow' => workflow, 'primary_branch' => observed(main, head ? 'origin/HEAD' : 'Git refs fallback', head ? 'high' : 'medium') },
      'suggested' => {
        'version' => 1,
        'project' => { 'adapter' => rails_markers ? 'rails-standard' : 'rails-standard', 'source' => name, 'base_branch' => base_branch },
        'git' => { 'workflow' => workflow['value'] },
        'issues' => { 'provider' => default_issues },
        'framework' => { 'name' => rails_markers ? 'rails' : 'unknown', 'sidekiq' => !!sidekiq, 'redis' => !!redis },
        'storage' => { 'dumps_directory' => 'dumps' },
        'branches' => { 'feature_base' => feature_base, 'hotfix_base' => hotfix_base },
        'database' => { 'host' => 'localhost', 'port' => 5432, 'user' => db_user, 'prefix' => prefix, 'bootstrap' => 'schema' },
        'runtime' => { 'proxy' => proxy, 'domain' => domain }
      },
      'warnings' => [
        ('No origin remote: branch creation needs an origin remote' if remote.empty?),
        ('No origin tracking ref for proposed primary branch' if main_ref && !refs.include?(main_ref)),
        ('Rails is not detected: only Rails adapters are currently supported' unless rails_markers),
        ('PostgreSQL is not detected: Rails adapter setup requires PostgreSQL' unless postgres)
      ].compact
    }
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    repo = ARGV.shift || '.'
    format = ARGV.shift || '--json'
    raise ArgumentError, 'Usage: detect.rb REPOSITORY [--json|--text]' unless %w[--json --text].include?(format) && ARGV.empty?
    result = GitwoDetection.detect(repo)
    if format == '--json'
      puts JSON.pretty_generate(result)
    else
      puts "Gitwo detection: #{result['repository']}"
      result.fetch('detected').each do |key, value|
        puts "  #{key.ljust(17)} #{value['value'].inspect} (#{value['confidence']}, #{value['source']})"
      end
      puts "  #{'git workflow'.ljust(17)} #{result.dig('inferred', 'workflow', 'value')} (#{result.dig('inferred', 'workflow', 'confidence')})"
      result.fetch('warnings').each { |warning| warn "  [WARN] #{warning}" }
    end
  rescue ArgumentError, SystemCallError => e
    warn "gitwo detect: #{e.message}"
    exit 2
  end
end
