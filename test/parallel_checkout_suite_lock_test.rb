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
require 'open3'
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
  end

  def teardown
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

  def run_lock(name, *args, stdin: '')
    Open3.capture3(env, script(name), *args, stdin_data: stdin, chdir: @scratch, unsetenv_others: true)
  end

  # Starts a command under the lock and returns once it is running.
  def hold(name, seconds: 30)
    started = File.join(@scratch, "started-#{@holders.size}")
    pid = Process.spawn(env, script(name), 'sh', '-c', "echo $$ > #{started}; exec sleep #{seconds}",
                        chdir: @scratch, unsetenv_others: true)
    @holders << pid
    Timeout.timeout(10) { sleep 0.02 until File.size?(started) }
    pid
  end

  def release(pid)
    Process.kill('KILL', pid)
    Process.wait(pid)
  end

  def start_time(pid) = `LC_ALL=C ps -o lstart= -p #{pid}`.strip

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
    _out, err, status = run_lock(:checkout)
    assert_equal 64, status.exitstatus
    assert_includes err, 'Usage: bin/suite-lock'
  end

  def test_the_recorded_holder_is_the_command_itself_with_its_start_time_and_command_line
    pid = hold(:checkout)
    recorded_pid, recorded_start, recorded_command = File.read(holder_file).split("\n")
    assert_equal pid.to_s, recorded_pid
    assert_equal File.read(File.join(@scratch, 'started-0')).strip, recorded_pid
    assert_equal start_time(pid), recorded_start
    assert_includes recorded_command, 'sleep 30'
  end

  def test_refuses_a_second_run_at_once_naming_the_holder
    pid = hold(:checkout)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = run_lock(:checkout, 'sh', '-c', "echo ran > #{ran_log}")
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 5
    assert_refused(result, "process #{pid}", start_time(pid), 'sleep 30')
  end

  def test_every_readable_layout_of_one_checkout_shares_the_lock
    hold(:outside)
    %i[checkout subdirectory nested crlf].each do |name|
      assert_refused(run_lock(name, 'sh', '-c', "echo ran > #{ran_log}"), 'sleep 30')
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
    assert_refused(run_lock(:checkout, 'sh', '-c', "echo ran > #{ran_log}"), 'being taken')
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
    assert_refused(run_lock(:checkout, '--wait', 'sh', '-c', "echo ran > #{ran_log}"),
                   "#{lock_dir}.takeover", 'remove it')
  end

  # Eight runs start together against a holder that is gone. Each one
  # that gets the lock keeps it for longer than the others take to be
  # refused, so more than one line in the log means two held it at once.
  def test_only_one_of_many_contenders_takes_over_from_a_dead_holder
    6.times do |round|
      FileUtils.rm_rf(ran_log)
      write_holder(pid: dead_pid, start: 'Thu Jan  1 00:00:00 1970')
      pids = Array.new(8) do
        Process.spawn(env, script(:checkout), 'sh', '-c', "echo ran >> #{ran_log}; exec sleep 1",
                      chdir: @scratch, unsetenv_others: true, err: File::NULL)
      end
      statuses = pids.map { |pid| Process.wait2(pid).last.exitstatus }
      assert_equal 1, File.readlines(ran_log).size, "round #{round}: #{statuses}"
      assert_equal [0] + ([REFUSED] * 7), statuses.sort, "round #{round}"
    end
  end

  # The holder here is this test's own child, so once killed it stays in
  # the process table until the test collects it.
  def test_a_holder_that_exited_and_was_not_collected_by_its_parent_is_gone
    Process.kill('KILL', hold(:checkout))
    sleep 0.2
    assert_took_the_lock(run_lock(:checkout, 'echo', 'ran'), 'echo ran')
  end

  def test_wait_runs_the_command_after_the_holder_exits
    hold(:checkout, seconds: 2)
    out, _err, status = Timeout.timeout(20) { run_lock(:outside, '--wait', 'echo', 'waited') }
    assert_equal "waited\n", out
    assert_predicate status, :success?
  end

  def test_explains_a_worktree_whose_git_directory_cannot_be_found
    %i[missing unreachable].each do |name|
      _out, err, status = run_lock(name, 'sh', '-c', "echo ran > #{ran_log}")
      assert_equal 78, status.exitstatus, name.to_s
      assert_includes err, 'cannot find the git directory'
      refute File.exist?(ran_log)
    end
  end

  def test_never_runs_git
    hold(:nested)
    run_lock(:crlf, 'true')
    run_lock(:missing, 'true')
    refute File.exist?(git_log), 'the template ran git'
  end
end
