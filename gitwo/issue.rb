#!/usr/bin/env ruby
# Resolve Jira issue identifiers and build safe Git branch suffixes.
# Uses only the Ruby standard library. Never logs API credentials.
require 'base64'
require 'json'
require 'net/http'
require 'uri'
require 'digest'
require 'optparse'
require 'unicode_normalize/normalize'

ISSUE_KEY = /\A[A-Z][A-Z0-9]{1,14}-[0-9]{1,10}\z/
UA_TRANSLITERATION = {
  'а' => 'a', 'б' => 'b', 'в' => 'v', 'г' => 'h', 'ґ' => 'g', 'д' => 'd',
  'е' => 'e', 'є' => 'ye', 'ж' => 'zh', 'з' => 'z', 'и' => 'y', 'і' => 'i',
  'ї' => 'yi', 'й' => 'i', 'к' => 'k', 'л' => 'l', 'м' => 'm', 'н' => 'n',
  'о' => 'o', 'п' => 'p', 'р' => 'r', 'с' => 's', 'т' => 't', 'у' => 'u',
  'ф' => 'f', 'х' => 'kh', 'ц' => 'ts', 'ч' => 'ch', 'ш' => 'sh', 'щ' => 'shch',
  'ь' => '', 'ю' => 'yu', 'я' => 'ya', 'ы' => 'y', 'э' => 'e', 'ё' => 'yo',
  'ъ' => '', 'ђ' => 'dj'
}.freeze

class JiraIssueError < StandardError; end

def parse_source(raw)
  value = raw.to_s.strip
  if value.match?(%r{\Ahttps?://}i)
    uri = URI.parse(value)
    raise JiraIssueError, 'Jira URL must use HTTPS' unless uri.scheme == 'https'
    raise JiraIssueError, 'Unexpected URL credentials' if uri.userinfo
    raise JiraIssueError, 'Unexpected URL port' unless uri.port == 443
    raise JiraIssueError, 'Missing Jira URL hostname' unless uri.host
    match = uri.path.match(%r{/(?:browse)/([A-Za-z][A-Za-z0-9]{1,14}-\d{1,10})(?:/|\z)}i)
    raise JiraIssueError, 'Expected Jira URL path: /browse/ENG-5303' unless match
    key = match[1].upcase
    allowed = ENV['JIRA_BASE_URL']
    if allowed && !allowed.empty?
      allowed_host = URI.parse(allowed).host
      raise JiraIssueError, 'Jira URL does not match JIRA_BASE_URL' unless uri.host.casecmp?(allowed_host)
    elsif !uri.host.end_with?('.atlassian.net')
      raise JiraIssueError, 'Custom Jira domain requires explicit JIRA_BASE_URL'
    end
    [key, uri]
  else
    [value.upcase, nil]
  end.tap do |key, _uri|
    raise JiraIssueError, "Invalid Jira issue ID: #{key}" unless key.match?(ISSUE_KEY)
  end
rescue URI::InvalidURIError
  raise JiraIssueError, 'Invalid Jira URL'
end

def normalize_title(input)
  input_text = input.to_s.dup.force_encoding(Encoding::UTF_8)
  raise JiraIssueError, 'Invalid UTF-8 title' unless input_text.valid_encoding?
  # Transliterate Cyrillic before Unicode normalization so ї/й keep their identity.
  text = input_text.each_char.map do |char|
    transliteration = UA_TRANSLITERATION[char.downcase]
    if transliteration
      char == char.upcase ? transliteration.upcase : transliteration
    else
      char.unicode_normalize(:nfkd).gsub(/\p{Mn}/, '')
    end
  end.join
  # Separate conventional CamelCase, retaining acronym runs like API and HTTP.
  text = text.gsub(/([A-Z]{2,})([A-Z][a-z])/, '\\1-\\2')
  text = text.gsub(/([a-z0-9])([A-Z])/, '\\1-\\2')
  tokens = text.scan(/[A-Za-z0-9]+/)
  tokens.map! do |word|
    # Uppercase runs of 3+ characters remain uppercase within a mixed token.
    word.gsub(/[A-Z]{3,}|[A-Z]{1,2}|[a-z0-9]+/) do |part|
      part.match?(/\A[A-Z]{3,}\z/) ? part : part.downcase
    end
  end
  slug = tokens.reject(&:empty?).join('-').gsub(/-+/, '-')
  raise JiraIssueError, 'Jira summary did not contain usable characters' if slug.empty?
  if slug.length > 76
    shortened = slug[0, 67].sub(/-[^-]*\z/, '').sub(/-+\z/, '')
    shortened = slug[0, 67].sub(/-+\z/, '') if shortened.length < 24
    slug = "#{shortened}-#{Digest::SHA256.hexdigest(slug)[0, 8]}"
  end
  slug
end

def jira_summary(key, source_url)
  base = ENV['JIRA_API_BASE_URL']
  if !base || base.empty?
    cloud_id = ENV['JIRA_CLOUD_ID']
    if cloud_id && !cloud_id.empty?
      raise JiraIssueError, 'Invalid JIRA_CLOUD_ID' unless cloud_id.match?(/\A[a-zA-Z0-9-]+\z/)
      base = "https://api.atlassian.com/ex/jira/#{cloud_id}"
    else
      base = ENV['JIRA_BASE_URL'] || (source_url && "https://#{source_url.host}")
    end
  end
  raise JiraIssueError, 'Set JIRA_BASE_URL to use an issue key without a Jira URL' unless base && !base.empty?
  uri = URI.parse(base)
  raise JiraIssueError, 'Jira API base must use HTTPS and no URL credentials' unless uri.scheme == 'https' && !uri.userinfo && uri.host && uri.port == 443
  raise JiraIssueError, 'Jira API base must not contain query or fragment' if uri.query || uri.fragment
  raise JiraIssueError, 'Jira API base must not have a trailing API path' if uri.path.include?('/rest/api/')
  url = URI.parse("#{base.sub(%r{/+\z}, '')}/rest/api/3/issue/#{key}?fields=summary")
  email = ENV['JIRA_EMAIL']
  token = ENV['JIRA_API_TOKEN']
  bearer = ENV['JIRA_BEARER_TOKEN']
  authorization = if bearer && !bearer.empty?
                    "Bearer #{bearer}"
                  elsif email && !email.empty? && token && !token.empty?
                    "Basic #{Base64.strict_encode64("#{email}:#{token}")}"
                  else
                    raise JiraIssueError, 'Set JIRA_EMAIL and JIRA_API_TOKEN (or JIRA_BEARER_TOKEN), or use --title / --offline'
                  end
  request = Net::HTTP::Get.new(url)
  request['Authorization'] = authorization
  request['Accept'] = 'application/json'
  request['User-Agent'] = 'gitwo/4.21'
  response = Net::HTTP.start(url.host, url.port, use_ssl: true, open_timeout: 7, read_timeout: 12) do |http|
    http.request(request)
  end
  unless response.is_a?(Net::HTTPSuccess)
    raise JiraIssueError, "Jira API returned HTTP #{response.code} for #{key} (permissions, token or URL may be incorrect)"
  end
  result = JSON.parse(response.body)
  summary = result.dig('fields', 'summary')
  raise JiraIssueError, "No summary for Jira issue #{key}" unless summary.is_a?(String) && !summary.strip.empty?
  summary
rescue JSON::ParserError
  raise JiraIssueError, 'Jira returned invalid JSON'
rescue URI::InvalidURIError
  raise JiraIssueError, 'Invalid Jira API base URL'
rescue SocketError, IOError, Timeout::Error, SystemCallError, OpenSSL::SSL::SSLError => e
  raise JiraIssueError, "Jira request failed (#{e.class})"
end

if $PROGRAM_NAME == __FILE__
begin
  command = ARGV.shift
  unless %w[key resolve describe slug].include?(command)
    raise JiraIssueError, 'Usage: issue.rb key <ID|URL> | resolve|describe <ID|URL> [--title TITLE] [--offline] | slug TITLE'
  end
  if command == 'slug'
    title = ARGV.join(' ')
    raise JiraIssueError, 'Pass title to slug command' if title.strip.empty?
    puts normalize_title(title)
    exit 0
  end
  raw = ARGV.shift
  raise JiraIssueError, 'Missing issue key or URL' unless raw && !raw.empty?
  options = { title: nil, offline: false }
  parser = OptionParser.new do |o|
    o.on('--title TITLE') { |value| options[:title] = value }
    o.on('--offline') { options[:offline] = true }
  end
  parser.parse!(ARGV)
  raise JiraIssueError, "Unexpected arguments: #{ARGV.join(' ')}" unless ARGV.empty?
  raise JiraIssueError, 'Cannot combine --title and --offline' if options[:offline] && options[:title]
  key, source_url = parse_source(raw)
  if command == 'key'
    puts key
    exit 0
  end
  title = options[:title]
  if !title && !options[:offline]
    configured = ENV.key?('JIRA_BASE_URL') || ENV.key?('JIRA_API_BASE_URL') || ENV.key?('JIRA_CLOUD_ID')
    if source_url || configured
      title = jira_summary(key, source_url)
    end
  end
  warn "WARN No Jira title configured; branch will use issue key only. Pass --title or configure Jira." unless title || options[:offline]
  slug = title ? normalize_title(title) : ''
  if command == 'describe'
    raise JiraIssueError, "No summary for Jira issue #{key}" if slug.empty?

    # A Jira title is remote data: strip control characters before displaying it.
    display_title = title.gsub(/[[:cntrl:]]/, ' ').gsub(/\s+/, ' ').strip
    puts "OK Jira connection verified"
    puts
    puts "Issue:   #{key}"
    puts "Title:   #{display_title}"
    puts "Slug:    #{slug}"
    puts
    puts 'Branch examples:'
    puts "  feature/#{key}-#{slug}"
    puts "  hotfix/#{key}-#{slug}"
  else
    # Preserve the machine-readable contract consumed by new.sh.
    puts "#{key}|#{slug}"
  end
rescue JiraIssueError, OptionParser::ParseError => e
  warn "ERROR #{e.message}"
  exit 2
end
end
