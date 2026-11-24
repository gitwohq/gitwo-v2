#!/usr/bin/env ruby
# frozen_string_literal: true

# Real local process-group supervision tests without Docker, Rails or network.
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'json'
require 'rbconfig'

def assert(condition, message)
  raise "Supervisor regression: #{message}" unless condition
end

def invoke(script, command, *args)
  stdout, stderr, status = Open3.capture3(RbConfig.ruby, script, command, *args)
  [stdout, stderr, status]
end

def await(seconds = 5)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
  until yield
    raise 'Supervisor regression: timed out' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    sleep 0.05
  end
end

Dir.mktmpdir('gitwo-supervisor.') do |tmp|
  supervisor = File.join(__dir__, 'supervisor.rb')
  runner = File.join(tmp, 'runner.sh')
  File.write(runner, <<~'SH')
    #!/usr/bin/env bash
    set -euo pipefail
    printf '%s\n' "$$" > "$1/child.pid"
    sleep 60 &
    printf '%s\n' "$!" > "$1/worker.pid"
    wait
  SH
  File.chmod(0755, runner)

  workspace_a = File.join(tmp, 'workspace-a')
  workspace_b = File.join(tmp, 'workspace-b')
  state_a = File.join(tmp, 'runtime', 'workspace-a')
  state_b = File.join(tmp, 'runtime', 'workspace-b')
  FileUtils.mkdir_p(workspace_a)
  FileUtils.mkdir_p(workspace_b)

  a = invoke(supervisor, 'start', workspace_a, state_a, runner, 'rails',
             'http://127.0.0.1:12001', 'json')
  assert(a[2].success?, "start A failed: #{a[1]}")
  data_a = JSON.parse(a[0])
  assert(data_a['status'] == 'starting' && data_a['readiness'] == 'not_verified',
         'startup event claimed readiness')
  assert(data_a['launcher'] == 'rails', 'startup lost launcher')
  assert(File.stat(File.join(state_a, 'supervisor.json')).mode & 077 == 0, 'unsafe record permissions')
  assert(File.stat(state_a).mode & 077 == 0, 'unsafe runtime directory permissions')
  await { File.file?(File.join(workspace_a, 'worker.pid')) }
  child_a = File.read(File.join(workspace_a, 'worker.pid')).to_i
  assert(child_a > 1, 'did not start background worker')

  status_a = invoke(supervisor, 'status', workspace_a, state_a, 'json')
  assert(status_a[2].success?, "status A failed: #{status_a[1]}")
  assert(JSON.parse(status_a[0])['status'] == 'running', 'active supervisor not recognized')
  duplicate = invoke(supervisor, 'start', workspace_a, state_a, runner, 'rails',
                     'http://127.0.0.1:12001', 'json')
  assert(!duplicate[2].success? && duplicate[1].include?('already supervised'),
         'duplicate up unexpectedly started')

  b = invoke(supervisor, 'start', workspace_b, state_b, runner, 'foreman',
             'http://127.0.0.1:12002', 'json')
  assert(b[2].success?, "start B failed: #{b[1]}")
  await { File.file?(File.join(workspace_b, 'worker.pid')) }
  status_b = invoke(supervisor, 'status', workspace_b, state_b, 'json')
  assert(JSON.parse(status_b[0])['status'] == 'running', 'second workspace not running')

  stopped_a = invoke(supervisor, 'stop', workspace_a, state_a, 'json')
  assert(stopped_a[2].success?, "stop A failed: #{stopped_a[1]}")
  assert(JSON.parse(stopped_a[0])['status'] == 'stopped', 'stop JSON did not report stopped')
  await { JSON.parse(invoke(supervisor, 'status', workspace_a, state_a, 'json')[0])['status'] == 'exited' }
  assert(JSON.parse(invoke(supervisor, 'status', workspace_b, state_b, 'json')[0])['status'] == 'running',
         'stopping one worktree affected another')
  worker_stat = IO.popen(['ps', '-p', child_a.to_s, '-o', 'stat='], &:read).to_s.strip
  assert(worker_stat.empty? || worker_stat.start_with?('Z'), 'owned worker survives shutdown')

  # Live foreign PID metadata must never authorize a signal.
  record_b = File.join(state_b, 'supervisor.json')
  saved = File.read(record_b)
  forged = JSON.parse(saved)
  forged['fingerprint'] = 'forged-process-start'
  File.write(record_b, JSON.generate(forged))
  refused = invoke(supervisor, 'stop', workspace_b, state_b)
  assert(!refused[2].success? && refused[1].include?('identity mismatch'),
         'foreign PID was signaled')
  File.write(record_b, saved)
  File.chmod(0600, record_b)
  assert(invoke(supervisor, 'stop', workspace_b, state_b)[2].success?, 'verified B could not stop')

  # Stale records should not be silently treated as successfully stopped.
  stale = JSON.parse(File.read(record_b))
  stale['pid'] = 999_999_999
  stale['status'] = 'starting'
  File.write(record_b, JSON.generate(stale))
  refused = invoke(supervisor, 'stop', workspace_b, state_b)
  assert(!refused[2].success? && refused[1].include?('stale or orphaned'), 'stale state was discarded')

  # Never follow state symlinks, even if they point to syntactically valid JSON.
  File.delete(record_b)
  File.symlink(File.join(state_a, 'supervisor.json'), record_b)
  refused = invoke(supervisor, 'stop', workspace_b, state_b)
  assert(!refused[2].success? && refused[1].include?('symlinked'), 'symlinked state accepted')
end

puts '[PASS] supervisor: detached process groups, duplicate refusal, cross-workspace isolation, verified group stop, forged PID, stale and symlink refusal'
