#!/usr/bin/env ruby
# Conservative, opt-in database.yml integration for native workspace commands.
# No application code or ERB is evaluated while preparing the patch.
require 'fileutils'
require 'securerandom'
require 'time'
require 'tempfile'

class GitwoRailsConfigError < StandardError; end

module GitwoRailsConfig
  module_function

  IDENTIFIER = /\A[A-Za-z_][A-Za-z0-9_-]*\z/

  def prepare(contents)
    raise GitwoRailsConfigError, 'database.yml must be valid UTF-8' unless contents.valid_encoding?
    raise GitwoRailsConfigError, 'CRLF is not supported; normalize file manually' if contents.include?("\r")
    raise GitwoRailsConfigError, 'database.yml cannot contain tabs' if contents.include?("\t")

    lines = contents.lines
    headers = lines.each_index.select { |i| lines[i].match?(/\A(?:development|test):\s*(?:#.*)?\n?\z/) }
    raise GitwoRailsConfigError, 'Expected exactly one top-level development: and test: block' unless
      headers.length == 2 && headers.map { |i| lines[i].split(':', 2).first }.sort == %w[development test]

    changes = []
    headers.each do |start|
      environment = lines[start].split(':', 2).first
      ending = ((start + 1)...lines.length).find { |i| lines[i].match?(/\A[^\s#][^\n]*:\s*(?:#.*)?\n?\z/) } || lines.length
      entries = ((start + 1)...ending).select { |i| lines[i].match?(/\A  database:/) }
      raise GitwoRailsConfigError, "#{environment} must have exactly one direct database: entry" unless entries.size == 1
      fields = lines[(start + 1)...ending]
      raise GitwoRailsConfigError, "#{environment} has URL/nested database config; manual integration required" if
        fields.any? { |line| line.match?(/\A  url:/) || line.match?(/\A {3,}(?:database|url|primary|replica):/) || line.match?(/\A  [a-zA-Z_][\w-]*:\s*(?:#.*)?\n?\z/) && !line.match?(/\A  database:/) }

      index = entries.first
      match = lines[index].match(/\A(  database:\s*)([^\n]*?)(\n?)\z/)
      raise GitwoRailsConfigError, "Unsupported #{environment} database entry" unless match
      value = match[2].strip
      variable = environment == 'development' ? 'GITWO_DB_DEV' : 'GITWO_DB_TEST'
      integrated = value.match(/\A<%= ENV\.fetch\("#{variable}", "([A-Za-z_][A-Za-z0-9_-]*)"\) %>\z/)
      if integrated
        next
      end
      fallback = value.delete_prefix('"').delete_suffix('"') if value.match?(/\A"[A-Za-z_][A-Za-z0-9_-]*"\z/)
      fallback ||= value.delete_prefix("'").delete_suffix("'") if value.match?(/\A'[A-Za-z_][A-Za-z0-9_-]*'\z/)
      fallback ||= value if IDENTIFIER.match?(value)
      raise GitwoRailsConfigError, "Unsupported #{environment} database value; do not rewrite ERB or custom Rails config automatically" unless fallback
      replacement = %(#{match[1]}<%= ENV.fetch("#{variable}", "#{fallback}") %>#{match[3]})
      changes << [environment, lines[index], replacement]
      lines[index] = replacement
    end
    [lines.join, changes]
  end

  def run(args)
    action, path, backup_dir = args
    raise GitwoRailsConfigError, 'Usage: rails-config.rb <plan|apply> PATH [BACKUP_DIR]' unless %w[plan apply].include?(action) && path
    raise GitwoRailsConfigError, 'Refusing symlinked or missing database.yml' unless File.file?(path) && !File.symlink?(path)
    contents = File.binread(path).force_encoding('UTF-8')
    updated, changes = prepare(contents)
    if changes.empty?
      puts '[OK] database.yml already uses Gitwo workspace DB variables in development/test'
      return
    end
    puts 'Proposed database.yml changes (existing database names remain fallbacks):'
    changes.each do |environment, before, after|
      puts "  #{environment}:"
      puts "    - #{before.strip}"
      puts "    + #{after.strip}"
    end
    if action == 'plan'
      puts 'No files changed. Run gitwo workspace env integrate --apply to update the tracked config explicitly.'
      return
    end

    raise GitwoRailsConfigError, 'Backup directory is required for --apply' unless backup_dir && !backup_dir.empty?
    raise GitwoRailsConfigError, 'Unsafe backup directory' if File.symlink?(backup_dir)
    FileUtils.mkdir_p(backup_dir, mode: 0700)
    raise GitwoRailsConfigError, 'Unsafe backup directory' unless File.directory?(backup_dir) && !File.symlink?(backup_dir)
    File.chmod(0700, backup_dir)
    stat = File.stat(path)
    backup = File.join(backup_dir, "database-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-#{SecureRandom.hex(5)}.yml")
    File.open(backup, File::WRONLY | File::CREAT | File::EXCL, 0600) { |f| f.write(contents) }
    Tempfile.create(['.gitwo-database-', '.tmp'], File.dirname(path)) do |tmp|
      tmp.write(updated)
      tmp.flush
      File.chmod(stat.mode & 0777, tmp.path)
      raise GitwoRailsConfigError, 'database.yml changed concurrently; aborting' unless File.binread(path) == contents
      File.rename(tmp.path, path)
    end
    puts "[OK] database.yml updated explicitly. Private backup: #{backup}"
    puts 'Review git diff -- config/database.yml and commit the change before creating new worktrees.'
  end
end

begin
  GitwoRailsConfig.run(ARGV)
rescue GitwoRailsConfigError, SystemCallError => e
  warn "gitwo: #{e.message}"
  exit 2
end
