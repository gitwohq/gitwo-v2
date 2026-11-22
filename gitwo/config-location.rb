#!/usr/bin/env ruby
# Resolve Gitwo configuration locations without evaluating project code.
# Paths depend only on the canonical checkout and XDG_CONFIG_HOME.
require 'digest'
require 'fileutils'
require 'pathname'
require 'securerandom'
require 'open3'

module GitwoConfigLocation
  module_function

  def canonical(project)
    File.realpath(File.expand_path(project))
  end

  def root
    base = ENV.fetch('XDG_CONFIG_HOME', File.join(Dir.home, '.config'))
    raise ArgumentError, 'XDG_CONFIG_HOME must be absolute' unless Pathname.new(base).absolute?
    File.join(File.expand_path(base), 'gitwo', 'projects')
  end

  def key(project)
    name = File.basename(project)
    raise ArgumentError, 'Unsafe checkout name' unless name.match?(/\A[A-Za-z][A-Za-z0-9_-]*\z/)
    "#{name}-#{Digest::SHA256.hexdigest(project)[0, 16]}"
  end

  def paths(project)
    project = canonical(project)
    basename = File.join(root, key(project))
    { project: project, default: "#{basename}.yml", pointer: "#{basename}.path",
      preference: "#{basename}.scope", team: File.join(project, 'gitwo.yml') }
  end

  def present?(path)
    File.exist?(path) || File.symlink?(path)
  end

  def read_private(path)
    return nil unless present?(path)
    raise ArgumentError, "Unsafe local Gitwo metadata: #{path}" unless
      File.file?(path) && !File.symlink?(path) &&
      File.stat(path).uid == Process.uid && (File.stat(path).mode & 0o077).zero?
    text = File.read(path, encoding: 'UTF-8').strip
    raise ArgumentError, "Malformed local Gitwo metadata: #{path}" if text.empty? || text.include?("\n")
    text
  end

  def validate_local_target(project, target)
    expanded = File.expand_path(target)
    raise ArgumentError, 'Local config must have an absolute path' unless Pathname.new(target).absolute?
    raise ArgumentError, 'Local config must stay outside the Git repository' if
      expanded == project || expanded.start_with?(project + File::SEPARATOR)
    raise ArgumentError, 'Local config must be a YAML file' unless expanded.end_with?('.yml', '.yaml')
    raise ArgumentError, "Refusing symlinked local config: #{expanded}" if File.symlink?(expanded)
    # macOS /var is normally a symlink to /private/var. Parent symlinks are
    # permitted when they resolve outside Git repositories; the file itself
    # must still be regular and may never be a symlink.
    # If the target is under another checkout (including a linked worktree),
    # local scope must not write there either.
    existing = File.dirname(expanded)
    existing = File.dirname(existing) until File.directory?(existing) || File.dirname(existing) == existing
    if File.directory?(existing)
      root, status = Open3.capture2('git', '-C', existing, 'rev-parse', '--show-toplevel', err: File::NULL)
      raise ArgumentError, 'Local config must not be inside any Git checkout' if status.success? && !root.strip.empty?
    end
    expanded
  end

  def local(project)
    locations = paths(project)
    stored = read_private(locations[:pointer])
    target = stored || locations[:default]
    validate_local_target(locations[:project], target)
  end

  def preference(project)
    locations = paths(project)
    value = read_private(locations[:preference])
    raise ArgumentError, 'Invalid stored Gitwo scope' unless value.nil? || %w[local team].include?(value)
    value
  end

  def scope(project, override = nil)
    if override
      raise ArgumentError, 'Scope must be local or team' unless %w[local team].include?(override)
      return override
    end
    from_env = ENV['GITWO_SCOPE']
    return scope(project, from_env) if from_env && !from_env.empty?
    saved = preference(project)
    return saved if saved
    # Previously configured team repositories remain usable until the user
    # explicitly selects local. New init defaults to local.
    return 'local' if present?(local(project))
    return 'team' if present?(paths(project)[:team])
    'local'
  end

  def active(project, requested = nil)
    locations = paths(project)
    scope(project, requested) == 'team' ? locations[:team] : local(project)
  end

  def prepare_directory(directory)
    path = File.expand_path(directory)
    current = path
    until File.directory?(current)
      raise ArgumentError, "Unsafe config directory: #{current}" if File.symlink?(current) || File.exist?(current)
      parent = File.dirname(current)
      raise ArgumentError, "Invalid directory: #{path}" if parent == current
      current = parent
    end
    raise ArgumentError, "Unsafe config directory: #{current}" if File.symlink?(current)
    FileUtils.mkdir_p(path, mode: 0o700)
  end

  def write_private(path, value)
    prepare_directory(File.dirname(path))
    raise ArgumentError, "Unsafe metadata target: #{path}" if File.symlink?(path)
    if File.file?(path)
      read_private(path)
    elsif File.exist?(path)
      raise ArgumentError, "Non-file metadata target: #{path}"
    end
    temporary = File.join(File.dirname(path), ".gitwo-#{SecureRandom.hex(12)}")
    begin
      File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write("#{value}\n")
      end
      File.rename(temporary, path)
    ensure
      File.unlink(temporary) if File.exist?(temporary)
    end
  end

  def register(project, target)
    locations = paths(project)
    target = validate_local_target(locations[:project], target)
    existing = read_private(locations[:pointer])
    if existing && existing != target
      raise ArgumentError, "Local config already registered at #{existing}; use that path or migrate explicitly"
    end
    if target != locations[:default]
      write_private(locations[:pointer], target) unless existing
    end
  end

  def use(project, requested)
    scope(project, requested)
    locations = paths(project)
    write_private(locations[:preference], requested)
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    action, project, third = ARGV
    raise ArgumentError, 'Usage: config-location.rb <active|local|team|scope|register|use> PROJECT [SCOPE_OR_PATH]' unless
      %w[active local team scope register use].include?(action) && project
    case action
    when 'active' then puts GitwoConfigLocation.active(project, third)
    when 'local' then puts GitwoConfigLocation.local(project)
    when 'team' then puts GitwoConfigLocation.paths(project)[:team]
    when 'scope' then puts GitwoConfigLocation.scope(project, third)
    when 'register'
      raise ArgumentError, 'register needs a local configuration path' unless third
      GitwoConfigLocation.register(project, third)
    when 'use'
      raise ArgumentError, 'use needs local or team' unless third
      GitwoConfigLocation.use(project, third)
    end
  rescue ArgumentError, SystemCallError => e
    warn "gitwo config location: #{e.message}"
    exit 2
  end
end
