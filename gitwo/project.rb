#!/usr/bin/env ruby
# Resolve a canonical primary Git checkout; never infer a random adjacent repo.
require 'open3'
require 'yaml'
module GitwoProject
  module_function
  def git(*args)
    output, status = Open3.capture2('git', *args, err: File::NULL)
    status.success? ? output.strip : nil
  rescue Errno::ENOENT
    nil
  end

  def validate_repo(path, _unused = nil)
    path = File.realpath(File.expand_path(path))
    root = git('-C', path, 'rev-parse', '--show-toplevel')
    raise ArgumentError, "Not a Git checkout: #{path}" unless root && File.directory?(root)
    linked = git('-C', root, 'worktree', 'list', '--porcelain')
    main = linked&.lines&.find { |line| line.start_with?('worktree ') }&.delete_prefix('worktree ')&.strip
    raise ArgumentError, 'Could not determine primary Git checkout' unless main && File.directory?(main)
    canonical = File.realpath(main)
    name = File.basename(canonical)
    raise ArgumentError, 'Unsafe primary checkout name' unless name.match?(/\A[A-Za-z][A-Za-z0-9_-]*\z/)
    canonical
  end

  def resolve(_script_dir = nil, explicit: nil, config_path: nil)
    if explicit
      return validate_repo(explicit)
    end
    if ENV['GITWO_PROJECT_ROOT'] && !ENV['GITWO_PROJECT_ROOT'].empty?
      return validate_repo(ENV.fetch('GITWO_PROJECT_ROOT'))
    end
    repo = git('rev-parse', '--show-toplevel')
    return validate_repo(repo) if repo
    if config_path && File.basename(config_path) == 'gitwo.yml' && File.file?(config_path) && !File.symlink?(config_path)
      return validate_repo(File.dirname(config_path))
    end
    raise ArgumentError, 'Run inside a Git checkout or pass --project=PATH (no automatic adjacent project selection)'
  end
end
