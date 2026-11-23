#!/usr/bin/env ruby
# frozen_string_literal: true

# Opt-in supervisor for a Gitwo-owned foreground dev launcher.
# Safety: a PID is never sufficient authority to send a signal. The process
# must still be the original group leader with matching start time and token.
require 'json'
require 'fileutils'
require 'rbconfig'
require 'securerandom'
require 'time'

module GitwoSupervisor
  module_function

  class Refusal < StandardError; end

  def verify_directory!(workspace, directory, create: false)
    raise Refusal, 'Workspace must be an existing absolute directory' unless
      workspace.start_with?('/') && File.directory?(workspace) && !File.symlink?(workspace)
    raise Refusal, 'Supervisor directory must be absolute' unless directory.start_with?('/')
    current = '/'
    directory.split('/').reject(&:empty?).each do |part|
      raise Refusal, 'Unsafe supervisor directory component' if part == '..' || part == '.'
      current = File.join(current, part)
      if File.symlink?(current)
        # macOS ships root-owned /var and /tmp aliases into /private.
        # Allow these exact OS aliases, never user-owned redirects.
        system_alias = %w[/var /tmp].include?(current) &&
          File.lstat(current).uid.zero? &&
          File.realpath(current) == "/private#{current}" &&
          File.stat('/private').uid.zero?
        raise Refusal, "Symlink in supervisor directory: #{current}" unless system_alias
      end
    end
    FileUtils.mkdir_p(directory, mode: 0700) if create
    return false unless File.directory?(directory)
    raise Refusal, 'Supervisor directory must belong to the current user' unless File.stat(directory).uid == Process.uid
    # Other Gitwo-managed Compose helpers may already have created this
    # directory with the system umask. Tighten it only during explicit start.
    File.chmod(0700, directory) if create
    raise Refusal, 'Supervisor directory permissions too broad' unless File.stat(directory).mode & 077 == 0
    true
  end

  def state_path(directory)
    File.join(directory, 'supervisor.json')
  end

  def lock_path(directory)
    File.join(directory, 'supervisor.lock')
  end

  def read_record(directory, workspace)
    path = state_path(directory)
    return nil unless File.exist?(path) || File.symlink?(path)
    raise Refusal, 'Refusing symlinked or non-file supervisor state' unless File.file?(path) && !File.symlink?(path)
    raise Refusal, 'Unsafe supervisor state permissions/ownership' unless
      File.stat(path).uid == Process.uid && File.stat(path).mode & 077 == 0 && File.size(path) <= 16_384
    record = JSON.parse(File.read(path))
    raise Refusal, 'Unexpected supervisor record' unless record.is_a?(Hash) &&
      record['version'] == 1 && record['workspace'] == workspace &&
      record['session'].is_a?(String) && record['session'].match?(/\A[0-9a-f]{32}\z/) &&
      record['pid'].is_a?(Integer) && record['pid'] > 1 &&
      record['fingerprint'].is_a?(String) && !record['fingerprint'].empty? &&
      record['launcher'].is_a?(String) && record['status'].is_a?(String)
    record
  rescue JSON::ParserError
    raise Refusal, 'Invalid supervisor JSON; inspect before restarting or stopping'
  end

  def write_record(directory, record)
    path = state_path(directory)
    raise Refusal, 'Refusing symlinked supervisor state' if File.symlink?(path)
    temp = File.join(directory, ".supervisor.#{Process.pid}.#{SecureRandom.hex(6)}.tmp")
    File.open(temp, File::WRONLY | File::CREAT | File::EXCL, 0600) do |file|
      file.write(JSON.generate(record) + "\n")
      file.flush
      file.fsync
    end
    File.rename(temp, path)
  ensure
    File.unlink(temp) if temp && File.exist?(temp)
  end

  def start_identity(pid)
    if File.file?("/proc/#{pid}/stat")
      data = File.read("/proc/#{pid}/stat")
      fields = data.split(/\)\s/, 2).last.to_s.split
      return "linux:#{fields.fetch(19)}" if fields.length > 19
    end
    value = IO.popen(['ps', '-p', pid.to_s, '-o', 'lstart='], &:read).to_s.strip
    value.empty? ? nil : "ps:#{value}"
  rescue Errno::ENOENT, Errno::ESRCH, IndexError
    nil
  end

  def alive?(pid)
    Process.kill(0, pid)
    stat = IO.popen(['ps', '-p', pid.to_s, '-o', 'stat='], &:read).to_s.strip
    !stat.start_with?('Z') && !stat.empty?
  rescue Errno::ESRCH, Errno::ENOENT
    false
  rescue Errno::EPERM
    true
  end

  def command_line(pid)
    path = "/proc/#{pid}/cmdline"
    if File.file?(path)
      File.binread(path).split("\0").join(' ')
    else
      IO.popen(['ps', '-ww', '-p', pid.to_s, '-o', 'command='], &:read).to_s
    end
  rescue Errno::ENOENT, Errno::ESRCH
    ''
  end

  def verified?(record)
    pid = record.fetch('pid')
    return false unless alive?(pid)
    return false unless Process.getpgid(pid) == pid
    return false unless start_identity(pid) == record.fetch('fingerprint')
    cmd = command_line(pid)
    cmd.include?('supervisor.rb') && cmd.include?(' serve ') &&
      cmd.include?(record.fetch('session'))
  rescue Errno::ESRCH, Errno::EPERM
    false
  end

  def leader_present?(record)
    alive?(record.fetch('pid'))
  end

  def status_data(record)
    return { 'status' => 'not_supervised' } unless record
    if verified?(record)
      {
        'status' => 'running',
        'pid' => record.fetch('pid'),
        'launcher' => record.fetch('launcher'),
        'workspace' => record.fetch('workspace'),
        'url' => record['url'],
        'log' => record['log']
      }
    elsif leader_present?(record)
      {
        'status' => 'unverified',
        'pid' => record.fetch('pid'),
        'reason' => 'PID ownership or process start identity changed; no signals permitted'
      }
    else
      {
        'status' => record['status'] == 'exited' ? 'exited' : (record['status'] == 'orphaned' ? 'orphaned' : 'stale'),
        'exit_code' => record['exit_code'],
        'launcher' => record['launcher']
      }
    end
  end

  def with_lock(directory)
    path = lock_path(directory)
    raise Refusal, 'Refusing symlinked supervisor lock' if File.symlink?(path)
    File.open(path, File::RDWR | File::CREAT, 0600) do |file|
      raise Refusal, 'Unsafe supervisor lock' unless file.stat.uid == Process.uid &&
        file.stat.mode & 077 == 0 && file.stat.nlink == 1
      file.flock(File::LOCK_EX)
      yield
    ensure
      file.flock(File::LOCK_UN)
    end
  end

  def group_members(pgid)
    # Spawn ps outside the supervised group. Otherwise its own PID makes the
    # group appear permanently active while we inspect it.
    ps = IO.popen(['ps', '-axo', 'pid=,pgid=,stat='], 'r', pgroup: true, &:read).to_s
    ps.each_line.filter_map do |line|
      pid, group, stat = line.split
      pid.to_i if group.to_i == pgid && pid.to_i != pgid && !stat.to_s.start_with?('Z')
    end
  end

  def start(workspace, directory, runner, launcher, url, format, arguments)
    verify_directory!(workspace, directory, create: true)
    raise Refusal, 'Runner must be an existing absolute script' unless runner.start_with?('/') && File.file?(runner)
    raise Refusal, 'Unsupported detached launcher' unless %w[rails bin-dev foreman].include?(launcher)
    raise Refusal, 'Invalid URL' unless url.start_with?('https://', 'http://')
    with_lock(directory) do
      previous = read_record(directory, workspace)
      if previous && leader_present?(previous)
        raise Refusal, verified?(previous) ? 'Workspace launcher already supervised and running' :
          'Supervisor PID is live but unverified; refusing to replace process identity'
      end
      if previous && previous['status'] != 'exited'
        raise Refusal, 'Previous supervisor exited without verified cleanup; inspect orphaned/stale processes before restarting'
      end
      session = SecureRandom.hex(16)
      log = File.join(directory, 'supervisor.log')
      raise Refusal, 'Unsafe supervisor log' if File.symlink?(log) || (File.exist?(log) && !File.file?(log))
      File.open(log, File::WRONLY | File::CREAT | File::APPEND, 0600) { |f| f.puts('[Gitwo supervisor] starting new launcher') }
      cmd = [RbConfig.ruby, File.expand_path(__FILE__), 'serve',
             workspace, directory, runner, launcher, url, session, *arguments]
      pid = Process.spawn(*cmd, pgroup: true, chdir: workspace, in: File::NULL, out: [log, 'a'], err: [log, 'a'], close_others: true)
      found = nil
      100.times do
        sleep 0.05
        candidate = read_record(directory, workspace)
        if candidate && candidate['session'] == session && candidate['pid'] == pid
          found = candidate
          break
        end
        begin
          Process.kill(0, pid)
        rescue Errno::ESRCH
          break
        end
      end
      raise Refusal, "Supervisor failed to initialize; inspect #{log}" unless found && verified?(found)
      result = {
        'status' => 'starting',
        'workspace' => File.basename(workspace),
        'launcher' => launcher,
        'pid' => pid,
        'url' => url,
        'log' => log,
        'readiness' => 'not_verified'
      }
      if format == 'json'
        puts JSON.generate(result)
      else
        puts "Gitwo launcher supervised: #{result.fetch('workspace')} (PID #{pid})"
        puts "URL: #{url}"
        puts "Log: #{log}"
        puts 'Readiness: not verified; inspect gitwo status --check-http'
      end
    end
  end

  def serve(workspace, directory, runner, launcher, url, session, arguments)
    verify_directory!(workspace, directory, create: true)
    raise Refusal, 'Supervisor is not its process-group leader' unless Process.getpgid(0) == Process.pid
    record = {
      'version' => 1,
      'workspace' => workspace,
      'session' => session,
      'pid' => Process.pid,
      'fingerprint' => start_identity(Process.pid),
      'launcher' => launcher,
      'url' => url,
      'log' => File.join(directory, 'supervisor.log'),
      'status' => 'starting',
      'started_at' => Time.now.utc.iso8601
    }
    raise Refusal, 'Cannot identify supervisor process start time' unless record['fingerprint']
    write_record(directory, record)
    stopping = false
    Signal.trap('TERM') { stopping = true }
    Signal.trap('INT') { stopping = true }
    child = Process.spawn({ 'GITWO_SUPERVISED_CHILD' => session }, 'bash', runner,
                          workspace, "--launcher=#{launcher}", 'server', *arguments,
                          chdir: workspace)
    status = nil
    begin
      _, status = Process.waitpid2(child)
    rescue Errno::EINTR
      retry
    rescue Errno::ECHILD
      status = nil
    ensure
      # A process manager may exit while its child watchers are still alive.
      # Only signal this private process group while its owner is still leader.
      if group_members(Process.pid).any?
        Process.kill('TERM', -Process.pid) rescue nil
        100.times do
          break if group_members(Process.pid).empty?
          sleep 0.1
        end
      end
      record['exit_code'] = status ? (status.exitstatus || 128 + status.termsig.to_i) : 1
      record['status'] = group_members(Process.pid).empty? ? 'exited' : 'orphaned'
      record['stopped_at'] = Time.now.utc.iso8601
      current = read_record(directory, workspace)
      write_record(directory, record) if current && current['session'] == session
    end
  end

  def stop(workspace, directory, format)
    verify_directory!(workspace, directory)
    with_lock(directory) do
      record = read_record(directory, workspace)
      if record.nil?
        puts(format == 'json' ? JSON.generate({ 'status' => 'not_supervised' }) : 'No supervised launcher')
        return
      end
      if leader_present?(record) && !verified?(record)
        raise Refusal, 'Supervisor process identity mismatch; refusing to signal a foreign process'
      end
      if !leader_present?(record) && record['status'] != 'exited'
        raise Refusal, 'Supervisor is stale or orphaned; refusing to claim safe shutdown without process ownership'
      end
      if verified?(record)
        Process.kill('TERM', -record.fetch('pid'))
        120.times do
          break unless leader_present?(record)
          sleep 0.1
        end
        raise Refusal, 'Supervisor did not terminate within grace period; no force kill attempted' if leader_present?(record)
      end
      puts(format == 'json' ? JSON.generate({ 'status' => 'stopped', 'workspace' => File.basename(workspace) }) :
        "Stopped supervised launcher for #{File.basename(workspace)}")
    end
  end

  def status(workspace, directory, format)
    verify_directory!(workspace, directory)
    result = status_data(read_record(directory, workspace))
    if format == 'json'
      puts JSON.generate(result)
    else
      puts case result.fetch('status')
           when 'running' then "running (supervised PID #{result.fetch('pid')}, #{result.fetch('launcher')})"
           when 'unverified' then "UNVERIFIED (PID #{result.fetch('pid')})"
           else result.fetch('status')
           end
    end
    exit 2 if %w[unverified orphaned stale].include?(result['status'])
  end

  def main
    action = ARGV.shift
    case action
    when 'start'
      raise Refusal, 'Usage: supervisor.rb start WORKSPACE DIRECTORY RUNNER LAUNCHER URL FORMAT [ARGS]' if ARGV.length < 6
      workspace, directory, runner, launcher, url, format, *args = ARGV
      start(workspace, directory, runner, launcher, url, format, args)
    when 'serve'
      raise Refusal, 'Usage: supervisor.rb serve WORKSPACE DIRECTORY RUNNER LAUNCHER URL SESSION [ARGS]' if ARGV.length < 6
      workspace, directory, runner, launcher, url, session, *args = ARGV
      serve(workspace, directory, runner, launcher, url, session, args)
    when 'verify-child'
      workspace, directory, session = ARGV
      raise Refusal, 'Usage: supervisor.rb verify-child WORKSPACE DIRECTORY SESSION' unless
        workspace && directory && session && ARGV.length == 3
      verify_directory!(workspace, directory)
      record = read_record(directory, workspace)
      raise Refusal, 'Unverified supervised launcher session' unless record &&
        record['session'] == session && verified?(record)
      exit 0
    when 'exists'
      workspace, directory = ARGV
      raise Refusal, 'Usage: supervisor.rb exists WORKSPACE DIRECTORY' unless workspace && directory && ARGV.length == 2
      verify_directory!(workspace, directory)
      path = state_path(directory)
      exit((File.exist?(path) || File.symlink?(path)) ? 0 : 1)
    when 'status', 'stop'
      workspace, directory, format = ARGV
      raise Refusal, "Usage: supervisor.rb #{action} WORKSPACE DIRECTORY [json]" unless workspace && directory
      public_send(action, workspace, directory, format == 'json' ? 'json' : 'text')
    else
      raise Refusal, 'Usage: supervisor.rb <start|serve|exists|status|stop> ...'
    end
  rescue Refusal, ArgumentError, SystemCallError => e
    warn "gitwo supervisor: #{e.message}"
    exit 1
  end
end

GitwoSupervisor.main if $PROGRAM_NAME == __FILE__
