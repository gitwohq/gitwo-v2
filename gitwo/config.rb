#!/usr/bin/env ruby
# Strict, read-only configuration parser for the local Gitwo Bash prototype.
# YAML is data, never executable shell code. Do not add credentials here.
require 'yaml'

SCHEMA = {
  'project' => {
    'adapter' => 'GITWO_ADAPTER',
    'source' => 'GITWO_PROJECT_SOURCE',
    'base_branch' => 'GITWO_BASE_BRANCH'
  },
  'git' => {
    'workflow' => 'GITWO_GIT_WORKFLOW'
  },
  'issues' => {
    'provider' => 'GITWO_ISSUE_PROVIDER',
    'url' => 'GITWO_ISSUE_URL',
    'credential' => 'GITWO_CREDENTIAL_PROFILE'
  },
  'framework' => {
    'name' => 'GITWO_FRAMEWORK',
    'sidekiq' => 'GITWO_HAS_SIDEKIQ',
    'redis' => 'GITWO_HAS_REDIS'
  },
  'storage' => {
    'dumps_directory' => 'GITWO_DUMPS_DIR'
  },
  'branches' => {
    'feature_base' => 'GITWO_FEATURE_BASE',
    'hotfix_base' => 'GITWO_HOTFIX_BASE'
  },
  'database' => {
    'host' => 'GITWO_DB_HOST',
    'port' => 'GITWO_DB_PORT',
    'user' => 'GITWO_DB_USER',
    'prefix' => 'GITWO_DB_PREFIX',
    'bootstrap' => 'GITWO_BOOTSTRAP'
  },
  'services' => {
    'backend' => 'GITWO_SERVICES_BACKEND'
  },
  'runtime' => {
    'proxy' => 'GITWO_PROXY',
    'domain' => 'GITWO_DOMAIN'
  }
}.freeze

class ConfigError < StandardError; end

def read_config(path)
  raise ConfigError, "Not a regular configuration file: #{path}" unless File.file?(path) && !File.symlink?(path)
  yaml_text = File.read(path)
  # Psych 3 (macOS system Ruby) uses positional arguments; Psych 4+ uses keywords.
  data = if Psych::VERSION.split('.').first.to_i >= 4
           YAML.safe_load(yaml_text, permitted_classes: [], permitted_symbols: [], aliases: false)
         else
           YAML.safe_load(yaml_text, [], [], false)
         end
  raise ConfigError, 'Configuration must be a YAML mapping' unless data.is_a?(Hash)
  unknown = data.keys - ['version', *SCHEMA.keys]
  raise ConfigError, "Unknown top-level keys: #{unknown.join(', ')}" unless unknown.empty?
  raise ConfigError, 'Expected version: 1' unless data['version'] == 1

  result = {}
  SCHEMA.each do |section, fields|
    content = data.fetch(section, {})
    raise ConfigError, "#{section} must be a YAML mapping" unless content.is_a?(Hash)
    extras = content.keys - fields.keys
    raise ConfigError, "Unknown #{section} keys: #{extras.join(', ')}" unless extras.empty?
    content.each do |key, value|
      env_key = fields.fetch(key)
      validate_value(env_key, value)
      result[env_key] = value.to_s
    end
  end
  result
end

def validate_value(key, value)
  case key
  when 'GITWO_GIT_WORKFLOW'
    valid = %w[gitflow github-flow trunk-based gitlab-flow custom].include?(value)
  when 'GITWO_ISSUE_PROVIDER'
    valid = %w[jira linear github none].include?(value)
  when 'GITWO_CREDENTIAL_PROFILE'
    valid = value.is_a?(String) && value.match?(/\A[a-z][a-z0-9_-]{0,31}\z/)
  when 'GITWO_ISSUE_URL'
    valid = value.is_a?(String) && value.length <= 256 && value.match?(%r{\Ahttps://[A-Za-z0-9.-]+(?::[0-9]{2,5})?(?:/[A-Za-z0-9._/-]*)?\z})
  when 'GITWO_FRAMEWORK'
    valid = %w[rails unknown].include?(value)
  when 'GITWO_HAS_SIDEKIQ', 'GITWO_HAS_REDIS'
    valid = value == true || value == false
  when 'GITWO_BOOTSTRAP'
    valid = %w[schema seeds].include?(value)
  when 'GITWO_ADAPTER'
    valid = %w[rails-webpack rails-standard].include?(value)
  when 'GITWO_PROJECT_SOURCE', 'GITWO_DUMPS_DIR'
    valid = value.is_a?(String) && value.match?(%r{\A[a-zA-Z][a-zA-Z0-9_-]*\z})
  when 'GITWO_BASE_BRANCH'
    valid = value.is_a?(String) && value.match?(%r{\A[a-zA-Z][a-zA-Z0-9._-]*\z}) && !value.include?('..') && !value.end_with?('.lock')
  when 'GITWO_DB_PREFIX'
    valid = value.is_a?(String) && value.match?(%r{\A[a-z][a-z0-9_]{0,20}\z})
  when 'GITWO_FEATURE_BASE', 'GITWO_HOTFIX_BASE'
    valid = value.is_a?(String) && value.match?(%r{\Aorigin/[A-Za-z0-9][A-Za-z0-9._/-]*\z}) &&
      !value.include?('..') && !value.include?('//') && !value.end_with?('.', '/') &&
      !value.split('/').any? { |part| part.start_with?('.') || part.end_with?('.lock') }
  when 'GITWO_DB_HOST'
    valid = %w[localhost 127.0.0.1].include?(value)
  when 'GITWO_DB_PORT'
    valid = value.to_s.match?(%r{\A[0-9]+\z}) && value.to_i.between?(1024, 65_535)
  when 'GITWO_DB_USER'
    valid = value.is_a?(String) && value.match?(%r{\A[A-Za-z_][A-Za-z0-9_]*\z})
  when 'GITWO_SERVICES_BACKEND'
    valid = %w[native compose].include?(value)
  when 'GITWO_PROXY'
    valid = %w[portless none].include?(value)
  when 'GITWO_DOMAIN'
    valid = value.is_a?(String) && value.length <= 63 && value.match?(%r{\A[a-z][a-z0-9]*(?:-[a-z0-9]+)*\z})
  else
    valid = false
  end
  raise ConfigError, "Invalid #{key} value" unless valid
end

begin
  command, path = ARGV
  raise ConfigError, 'Usage: config.rb <export|validate> CONFIG_FILE' unless %w[export validate].include?(command) && path && ARGV.length == 2
  parsed = read_config(path)
  if command == 'export'
    # All values are validated to contain no whitespace, shell syntax or newlines.
    parsed.each { |key, value| puts "#{key}=#{value}" }
  else
    puts "Configuration valid: #{path}"
  end
rescue ConfigError, Psych::Exception, EncodingError, SystemCallError => e
  warn "gitwo config: #{e.message}"
  exit 2
end
