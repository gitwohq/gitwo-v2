#!/usr/bin/env ruby
# Safe issue lookup. No authentication values are printed or persisted.
require 'json'
require 'net/http'
require 'uri'
require 'open3'
require 'optparse'
require_relative 'issue'

class GitwoProviderError < StandardError; end

module GitwoProvider
  module_function
  KEY = /\A[A-Z][A-Z0-9]{1,14}-[0-9]{1,10}\z/

  def provider
    value = ENV.fetch('GITWO_ISSUE_PROVIDER', 'none')
    raise GitwoProviderError, "Unsupported issue provider: #{value}" unless %w[jira linear github none].include?(value)
    value
  end

  def parse(raw)
    raw = raw.to_s.strip
    case provider
    when 'jira'
      key, url = parse_source(raw)
      [key, url]
    when 'github'
      if (m = raw.match(%r{\Ahttps://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/issues/([1-9]\d*)(?:/)?\z}))
        raise GitwoProviderError, 'GitHub repository does not match configured repository' unless github_repo == "#{m[1]}/#{m[2].delete_suffix('.git')}"
        ["GH-#{m[3]}", nil]
      elsif (m = raw.match(/\A(?:GH-|#)?([1-9]\d*)\z/i))
        ["GH-#{m[1]}", nil]
      else
        raise GitwoProviderError, 'GitHub issue must be #123, 123, GH-123, or a github.com issue URL'
      end
    else
      key = raw.upcase
      raise GitwoProviderError, "Invalid issue identifier: #{raw}" unless KEY.match?(key)
      [key, nil]
    end
  rescue JiraIssueError => e
    raise GitwoProviderError, e.message
  end

  def github_repo
    configured = ENV['GITWO_ISSUE_URL']
    repo = if configured && !configured.empty?
             match = configured.match(%r{\Ahttps://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/?\z})
             raise GitwoProviderError, 'GitHub issues.url must be https://github.com/OWNER/REPO' unless match
             "#{match[1]}/#{match[2]}"
           else
             origin, status = Open3.capture2('git', '-C', ENV.fetch('GITWO_SOURCE', Dir.pwd), 'remote', 'get-url', 'origin', err: File::NULL)
             raise GitwoProviderError, 'Cannot detect GitHub origin; configure issues.url' unless status.success?
             origin = origin.strip
             match = origin.match(%r{\A(?:git@github\.com:|ssh://git@github\.com/|https://github\.com/)([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+?)(?:\.git)?/?\z})
             raise GitwoProviderError, 'Origin is not a supported GitHub repository; configure issues.url' unless match
             "#{match[1]}/#{match[2]}"
           end
    raise GitwoProviderError, 'Invalid GitHub repository' unless repo.match?(%r{\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z})
    repo
  end

  def github_title(key)
    number = key.delete_prefix('GH-')
    repo = github_repo
    output, status = Open3.capture2e('gh', 'api', "repos/#{repo}/issues/#{number}", '--jq', '{number:.number,title:.title,pull_request:(has("pull_request"))}')
    raise GitwoProviderError, 'GitHub request failed; run gh auth login and verify access' unless status.success?
    result = JSON.parse(output)
    raise GitwoProviderError, 'GitHub endpoint returned a Pull Request, not an issue' if result['pull_request']
    raise GitwoProviderError, 'Unexpected GitHub issue number' unless result['number'].to_s == number
    title = result['title']
    raise GitwoProviderError, 'GitHub issue has no title' unless title.is_a?(String) && !title.strip.empty?
    title
  rescue Errno::ENOENT
    raise GitwoProviderError, 'gh CLI is required for GitHub Issues; install and run gh auth login'
  rescue JSON::ParserError
    raise GitwoProviderError, 'GitHub returned invalid JSON'
  end

  def linear_title(key)
    token = ENV['LINEAR_API_KEY']
    raise GitwoProviderError, 'Missing LINEAR_API_KEY (set env or ~/.config/gitwo/linear.env)' if token.to_s.empty?
    uri = URI('https://api.linear.app/graphql')
    request = Net::HTTP::Post.new(uri)
    request['Authorization'] = token
    request['Content-Type'] = 'application/json'
    request['Accept'] = 'application/json'
    request.body = JSON.generate({ query: 'query GitwoIssue($id: String!) { issue(id: $id) { identifier title } }', variables: { id: key } })
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 7, read_timeout: 12) { |http| http.request(request) }
    raise GitwoProviderError, "Linear API returned HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)
    payload = JSON.parse(response.body)
    raise GitwoProviderError, 'Linear issue unavailable or insufficient permissions' if payload['errors'] || !payload.dig('data', 'issue').is_a?(Hash)
    issue = payload['data']['issue']
    raise GitwoProviderError, 'Unexpected Linear issue identifier' unless issue['identifier'] == key
    title = issue['title']
    raise GitwoProviderError, 'Linear issue has no title' unless title.is_a?(String) && !title.strip.empty?
    title
  rescue JSON::ParserError
    raise GitwoProviderError, 'Linear returned invalid JSON'
  rescue SocketError, IOError, Timeout::Error, SystemCallError, OpenSSL::SSL::SSLError
    raise GitwoProviderError, 'Linear API request failed'
  end

  def resolve(raw, title: nil, offline: false)
    key, url = parse(raw)
    if title.nil? && !offline
      title = case provider
              when 'jira' then jira_summary(key, url)
              when 'github' then github_title(key)
              when 'linear' then linear_title(key)
              else nil
              end
    end
    [key, title ? normalize_title(title) : '']
  rescue JiraIssueError => e
    raise GitwoProviderError, e.message
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    action = ARGV.shift
    raise GitwoProviderError, 'Usage: provider.rb <key|resolve> ISSUE [--title TITLE|--offline]' unless %w[key resolve].include?(action)
    raw = ARGV.shift
    raise GitwoProviderError, 'Missing issue identifier' if raw.to_s.empty?
    options = { title: nil, offline: false }
    OptionParser.new do |parser|
      parser.on('--title TITLE') { |value| options[:title] = value }
      parser.on('--offline') { options[:offline] = true }
    end.parse!(ARGV)
    raise GitwoProviderError, 'Unexpected arguments' unless ARGV.empty?
    raise GitwoProviderError, '--title and --offline cannot be combined' if options[:title] && options[:offline]
    key, slug = if action == 'key' then [GitwoProvider.parse(raw).first, '']
                else GitwoProvider.resolve(raw, **options) end
    puts action == 'key' ? key : "#{key}|#{slug}"
  rescue GitwoProviderError, OptionParser::ParseError => e
    warn "gitwo: #{e.message}"
    exit 2
  end
end
