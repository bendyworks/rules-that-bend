#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests for the parallel-checkouts skill's bin/suite-lock template, which
# runs a full-suite command while holding a lock every worktree of one
# checkout shares. Each test copies the template into the layouts of
# Fixtures::GitDirectoryLayouts and runs it as a project would. Where
# /bin/bash is 3.x the template runs under it, as the stack templates do.
# Coverage records nothing here: the project measures only bin/*.
# Run: ruby test/parallel_checkout_suite_lock_test.rb

require_relative 'cli_test_case'
require_relative 'fixtures/git_directory_layouts'
require 'shellwords'
require 'timeout'

class ParallelCheckoutSuiteLockTest < Minitest::Test
  TEMPLATE = File.expand_path('../skills/parallel-checkouts/templates/suite-lock', __dir__)
  SYSTEM_BASH = '/bin/bash'
  BASH3 = File.executable?(SYSTEM_BASH) && `#{SYSTEM_BASH} -c 'echo $BASH_VERSINFO'`.strip == '3'
  REFUSED = 75
  FAKE_GIT = <<~SH
    #!/bin/sh
    echo "$@" >> "$FAKE_GIT_LOG"
    exit 1
  SH

  def setup
    @scratch = File.realpath(Dir.mktmpdir('suite-lock'))
    @layouts = Fixtures::GitDirectoryLayouts.build(@scratch)
    @fakebin = File.join(@scratch, 'fakebin')
    FileUtils.mkdir_p(@fakebin)
    File.write(File.join(@fakebin, 'git'), FAKE_GIT)
    File.chmod(0o755, File.join(@fakebin, 'git'))
    File.symlink(SYSTEM_BASH, File.join(@fakebin, 'bash')) if BASH3
    @layouts.each_value { |layout| install(layout) }
    @holders = []
    @runs = 0
  end

  # The stand-in git is first on PATH in every test, so this covers
  # every path a test takes through the template.
  def teardown
    refute File.exist?(git_log), 'the template ran git'
  ensure
    @holders.each do |pid|
      Process.kill('KILL', pid)
      Process.wait(pid)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end
    FileUtils.rm_rf(@scratch)
  end

  def install(layout)
    FileUtils.mkdir_p(File.join(layout.path, 'bin'))
    FileUtils.cp(TEMPLATE, script(layout.name))
    File.chmod(0o755, script(layout.name))
  end

  def script(name) = File.join(@layouts.fetch(name).path, 'bin', 'suite-lock')
  def lock_dir = File.join(@layouts.fetch(:checkout).common_dir, 'suite-lock')
  def holder_file = File.join(lock_dir, 'holder')
  def git_log = File.join(@scratch, 'git-calls')
  def ran_log = File.join(@scratch, 'ran')

  def env
    keep = %w[HOME LANG TMPDIR].to_h { |key| [key, ENV.fetch(key, nil)] }
    keep.merge('PATH' => "#{@fakebin}:#{ENV.fetch('PATH')}", 'FAKE_GIT_LOG' => git_log)
  end

  # Runs the template to its end and returns its output, error output
  # and status. A run still going after `within` seconds is killed and
  # fails the test, so a run that waits when it should not is a failure
  # and not a suite that never finishes.
  def run_lock(name, *args, **options) = run_script(script(name), *args, **options)

  def run_script(path, *args, stdin: '', within: 30, vars: {})
    @runs += 1
    files = %w[in out err].to_h { |stream| [stream, File.join(@scratch, "run-#{@runs}.#{stream}")] }
    File.write(files['in'], stdin)
    pid = Process.spawn(env.merge(vars), path, *args, in: files['in'], out: files['out'], err: files['err'],
                                                  chdir: @scratch, unsetenv_others: true)
    status = wait_within(pid, within)
    unless status
      release(pid)
      flunk "suite-lock #{args.join(' ')} was still running after #{within} seconds: #{File.read(files['err'])}"
    end
    [File.read(files['out']), File.read(files['err']), status]
  end

  def wait_within(pid, seconds)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    loop do
      _pid, status = Process.wait2(pid, Process::WNOHANG)
      return status if status
      return nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.02
    end
  end

  # A command that leaves a mark when it runs, for a run that must not.
  def mark_ran = ['sh', '-c', "echo ran > #{ran_log.shellescape}"]

  # Starts a command under the lock and returns once it is running.
  def hold(name, seconds: 30, vars: {})
    started = File.join(@scratch, "started-#{@holders.size}")
    pid = Process.spawn(env.merge(vars), script(name), 'sh', '-c',
                        "echo $$ > #{started.shellescape}; exec sleep #{seconds}",
                        chdir: @scratch, unsetenv_others: true)
    @holders << pid
    Timeout.timeout(10) { sleep 0.02 until File.size?(started) }
    pid
  end

  def release(pid)
    Process.kill('KILL', pid)
    Process.wait(pid)
    @holders.delete(pid)
  end

  def process_state(pid) = `LC_ALL=C ps -o stat= -p #{pid}`.strip

  def start_time(pid) = `TZ=UTC LC_ALL=C ps -o lstart= -p #{pid}`.strip

  def write_holder(pid:, start:, command: 'rake')
    FileUtils.mkdir_p(lock_dir)
    File.write(holder_file, "#{pid}\n#{start}\n#{command}\n")
  end

  def dead_pid
    pid = Process.spawn('true')
    Process.wait(pid)
    pid
  end

  # The holder file outlives the command it names, so it shows which run
  # took the lock last.
  def assert_took_the_lock(result, command)
    out, err, status = result
    assert_predicate status, :success?, err
    assert_equal "ran\n", out
    assert_equal command, File.read(holder_file).split("\n").last
  end

  def assert_refused(result, *expected)
    _out, err, status = result
    assert_equal REFUSED, status.exitstatus, err
    expected.each { |text| assert_includes err, text.to_s }
    refute File.exist?(ran_log), 'the command ran despite the refusal'
  end

  def test_runs_the_command_and_passes_its_output_input_and_status_through
    out, err, status = run_lock(:checkout, 'sh', '-c', 'cat; echo to-stderr >&2; exit 3', stdin: 'from-stdin')
    assert_equal 'from-stdin', out
    assert_equal "to-stderr\n", err
    assert_equal 3, status.exitstatus
  end

  def test_asks_for_a_command_when_given_none
    [[], ['--wait'], ['--'], ['--wait', '--']].each do |args|
      _out, err, status = run_lock(:checkout, *args)
      assert_equal 64, status.exitstatus, args.inspect
      assert_includes err, 'Usage: bin/suite-lock'
    end
  end

  def test_a_double_dash_ends_the_options
    assert_took_the_lock(run_lock(:checkout, '--', 'echo', 'ran'), 'echo ran')
    assert_took_the_lock(run_lock(:checkout, '--wait', '--', 'echo', 'ran'), 'echo ran')
  end

  # bash's own exec takes options, so a command whose name begins with
  # a dash must not reach it as one.
  def test_runs_a_command_whose_name_begins_with_a_dash
    stand_in('--wait', 'echo ran')
    assert_took_the_lock(run_lock(:checkout, '--', '--wait'), '--wait')
    stand_in('-l', 'echo ran')
    assert_took_the_lock(run_lock(:checkout, '-l'), '-l')
  end

  def test_records_a_command_holding_a_newline_on_one_line
    assert_took_the_lock(run_lock(:checkout, 'sh', '-c', "echo ran\n:"), 'sh -c echo ran :')
    assert_equal 3, File.readlines(holder_file).size
  end

  def test_the_recorded_holder_is_the_command_itself_with_its_start_time_and_command_line
    pid = hold(:checkout)
    recorded_pid, recorded_start, recorded_command = File.read(holder_file).split("\n")
    assert_equal pid.to_s, recorded_pid
    assert_equal File.read(File.join(@scratch, 'started-0')).strip, recorded_pid
    assert_equal start_time(pid), recorded_start
    assert_includes recorded_command, 'sleep 30'
  end

  # The command line stays in the holder file after the run, so only
  # its owner may read it, and the command keeps the umask it was given.
  def test_only_the_owner_can_read_the_holder_file
    out, _err, _status = run_lock(:checkout, 'sh', '-c', 'umask')
    assert_equal 0o600, File.stat(holder_file).mode & 0o777
    assert_equal format('%04o', File.umask), out.strip
  end

  def test_refuses_a_second_run_at_once_naming_the_holder
    pid = hold(:checkout)
    assert_refused(run_lock(:checkout, *mark_ran, within: 5), "process #{pid}", start_time(pid), 'sleep 30')
  end

  # The holder file is text any process can have written, and a refusal
  # prints it to a terminal.
  def test_a_refusal_prints_no_control_characters_from_the_holder_file
    write_holder(pid: Process.pid, start: start_time(Process.pid), command: "rake\e[2Jspec\a")
    _out, err, status = run_lock(:checkout, *mark_ran)
    assert_equal REFUSED, status.exitstatus, err
    assert_includes err, 'running: rake[2Jspec.'
    refute_match(/[\e\a]/, err)
  end

  # ps prints a start time in the caller's time zone, so two runs that
  # disagree about the zone must still agree about the holder.
  def test_refuses_a_run_whose_time_zone_differs_from_the_holders
    pid = hold(:checkout, vars: { 'TZ' => 'America/Chicago' })
    assert_refused(run_lock(:checkout, *mark_ran, vars: { 'TZ' => 'Asia/Tokyo' }), "process #{pid}")
  end

  # Without a `gitdir:` line the directory holding the .git file would
  # be taken for the git directory, and a directory named suite-lock in
  # the working tree for a lock left behind.
  def test_a_git_file_that_names_no_git_directory_is_not_followed
    ['', "gitdir:\n", "gitdir:   \n", "../checkout/.git\n"].each do |content|
      project = File.join(@scratch, 'archive')
      FileUtils.mkdir_p(File.join(project, 'bin'))
      FileUtils.mkdir_p(File.join(project, 'suite-lock'))
      FileUtils.touch(File.join(project, 'suite-lock', 'kept'))
      File.utime(Time.now - 300, Time.now - 300, File.join(project, 'suite-lock'))
      File.write(File.join(project, '.git'), content)
      FileUtils.cp(TEMPLATE, File.join(project, 'bin', 'suite-lock'))
      _out, err, status = run_script(File.join(project, 'bin', 'suite-lock'), *mark_ran)
      assert_equal 78, status.exitstatus, "#{content.inspect}: #{err}"
      assert File.exist?(File.join(project, 'suite-lock', 'kept')), content.inspect
      refute File.exist?(ran_log), content.inspect
      FileUtils.rm_rf(project)
    end
  end

  def stand_in(name, body)
    File.write(File.join(@fakebin, name), "#!/bin/sh\n#{body}\n")
    File.chmod(0o755, File.join(@fakebin, name))
  end

  # A run that went on without a holder file, or with one holding no
  # start time, would be read as gone by every later run.
  def test_gives_the_lock_back_and_stops_when_it_cannot_record_itself_as_the_holder
    { 'ps' => 'exit 1', 'mv' => 'exit 1' }.each do |command, body|
      stand_in(command, body)
      _out, err, status = run_lock(:checkout, *mark_ran)
      assert_equal 78, status.exitstatus, "#{command}: #{err}"
      assert_includes err, 'cannot record this run as the holder'
      refute File.exist?(ran_log), command
      refute File.exist?(lock_dir), command
      FileUtils.rm_f(File.join(@fakebin, command))
    end
  end

  def test_gives_a_taken_over_lock_back_when_it_cannot_record_itself_as_the_holder
    write_holder(pid: dead_pid, start: 'Thu Jan  1 00:00:00 1970')
    stand_in('mv', 'exit 1')
    _out, err, status = run_lock(:checkout, *mark_ran)
    assert_equal 78, status.exitstatus, err
    refute File.exist?(ran_log)
    assert_empty Dir.glob("#{lock_dir}*")
  end

  def test_every_readable_layout_of_one_checkout_shares_the_lock
    hold(:outside)
    %i[checkout subdirectory nested crlf relative absolute_common crlf_common].each do |name|
      assert_refused(run_lock(name, *mark_ran), 'sleep 30')
    end
  end

  def test_runs_again_once_the_holder_has_exited_and_leaves_no_takeover_directory
    release(hold(:checkout))
    assert_took_the_lock(run_lock(:nested, 'echo', 'ran'), 'echo ran')
    assert_empty Dir.glob("#{lock_dir}.*")
  end

  def test_a_live_process_with_another_start_time_is_not_the_holder
    write_holder(pid: Process.pid, start: 'Thu Jan  1 00:00:00 1970')
    assert_took_the_lock(run_lock(:checkout, 'echo', 'ran'), 'echo ran')
  end

  def test_a_lock_directory_with_no_holder_file_yet_is_held
    FileUtils.mkdir_p(lock_dir)
    assert_refused(run_lock(:checkout, *mark_ran), 'being taken')
  end

  def test_a_lock_directory_left_without_a_holder_file_is_taken_over
    FileUtils.mkdir_p(lock_dir)
    File.utime(Time.now - 300, Time.now - 300, lock_dir)
    assert_took_the_lock(run_lock(:checkout, 'echo', 'ran'), 'echo ran')
  end

  # Removing another run's takeover directory by age would let two runs
  # into the takeover at once, so one left behind is a person's to clear.
  def test_an_abandoned_takeover_directory_is_refused_with_the_path_to_remove
    write_holder(pid: dead_pid, start: 'Thu Jan  1 00:00:00 1970')
    FileUtils.mkdir_p("#{lock_dir}.takeover")
    File.utime(Time.now - 300, Time.now - 300, "#{lock_dir}.takeover")
    assert_refused(run_lock(:checkout, '--wait', *mark_ran),
                   "#{lock_dir}.takeover", 'remove it')
  end

  def test_a_takeover_another_run_has_just_begun_is_refused_and_left_alone
    write_holder(pid: dead_pid, start: 'Thu Jan  1 00:00:00 1970')
    FileUtils.mkdir_p("#{lock_dir}.takeover")
    assert_refused(run_lock(:checkout, *mark_ran), 'being taken')
    assert File.directory?("#{lock_dir}.takeover")
  end

  def test_wait_takes_the_lock_once_another_runs_takeover_is_over
    write_holder(pid: dead_pid, start: 'Thu Jan  1 00:00:00 1970')
    FileUtils.mkdir_p("#{lock_dir}.takeover")
    finishing = Thread.new do
      sleep 1.5
      Dir.rmdir("#{lock_dir}.takeover")
    end
    assert_took_the_lock(run_lock(:checkout, '--wait', 'echo', 'ran'), 'echo ran')
    finishing.join
  end

  # Eight runs start together against a holder that is gone. Whichever
  # gets the lock keeps it until the other seven have been refused, so
  # a second line in the log means two held it at once.
  def test_only_one_of_many_contenders_takes_over_from_a_dead_holder
    6.times do |round|
      FileUtils.rm_rf(ran_log)
      FileUtils.rm_rf(lock_dir)
      write_holder(pid: dead_pid, start: 'Thu Jan  1 00:00:00 1970')
      pids = Array.new(8) do
        Process.spawn(env, script(:checkout), 'sh', '-c', "echo ran >> #{ran_log.shellescape}; exec sleep 30",
                      chdir: @scratch, unsetenv_others: true, err: File::NULL)
      end
      @holders.concat(pids)
      refused = refused_among(pids, 7)
      Timeout.timeout(10) { sleep 0.02 until File.size?(ran_log) }
      assert_equal [REFUSED] * 7, refused.values, "round #{round}"
      assert_equal 1, File.readlines(ran_log).size, "round #{round}"
      (pids - refused.keys).each { |pid| release(pid) }
    end
  end

  # Waits until `count` of the runs have exited, or twenty seconds, and
  # returns the exit status of each that has.
  def refused_among(pids, count)
    exited = {}
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 20
    while exited.size < count && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      (pids - exited.keys).each do |pid|
        _pid, status = Process.wait2(pid, Process::WNOHANG)
        exited[pid] = status.exitstatus if status
      end
      sleep 0.02
    end
    exited
  end

  # The holder here is this test's own child, so once killed it stays in
  # the process table until the test collects it.
  def test_a_holder_that_exited_and_was_not_collected_by_its_parent_is_gone
    pid = hold(:checkout)
    Process.kill('KILL', pid)
    Timeout.timeout(10) { sleep 0.02 until process_state(pid).start_with?('Z') }
    assert_took_the_lock(run_lock(:checkout, 'echo', 'ran'), 'echo ran')
  end

  def test_wait_runs_the_command_after_the_holder_exits
    hold(:checkout, seconds: 2)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    out, err, status = run_lock(:outside, '--wait', 'echo', 'waited')
    assert_predicate status, :success?, err
    assert_equal "waited\n", out
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :>, 1
    assert_equal 'echo waited', File.read(holder_file).split("\n").last
  end

  def test_explains_a_worktree_whose_git_directory_cannot_be_found
    %i[missing unreachable].each do |name|
      _out, err, status = run_lock(name, *mark_ran)
      assert_equal 78, status.exitstatus, name.to_s
      assert_includes err, 'cannot find the git directory'
      assert_includes err, 'mounted at another path'
      refute File.exist?(ran_log)
    end
  end

  def test_the_stand_in_git_records_a_call
    system(env, 'git', 'status', unsetenv_others: true, out: File::NULL, err: File::NULL)
    assert_equal "status\n", File.read(git_log)
    FileUtils.rm_f(git_log)
  end
end
