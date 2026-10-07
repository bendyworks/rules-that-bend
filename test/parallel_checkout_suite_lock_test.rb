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

  def install(layout) = install_in(layout.path)

  # Copies the template into a project's bin/ and returns its path.
  def install_in(project)
    copy = File.join(project, 'bin', 'suite-lock')
    FileUtils.mkdir_p(File.dirname(copy))
    FileUtils.cp(TEMPLATE, copy)
    File.chmod(0o755, copy)
    copy
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

  def run_script(path, *args, stdin: '', within: 30, vars: {}, umask: File.umask)
    @runs += 1
    files = %w[in out err].to_h { |stream| [stream, File.join(@scratch, "run-#{@runs}.#{stream}")] }
    File.write(files['in'], stdin)
    pid = Process.spawn(env.merge(vars), path, *args, in: files['in'], out: files['out'], err: files['err'],
                                                  chdir: @scratch, unsetenv_others: true, umask: umask)
    @holders << pid
    status = wait_within(pid, within)
    unless status
      release(pid)
      flunk "suite-lock #{args.join(' ')} was still running after #{within} seconds: #{File.read(files['err'])}"
    end
    [File.read(files['out']), File.read(files['err']), status]
  end

  # The status of a run once it has exited, or nil if it is still going
  # after `seconds`. A run that has been collected is no longer one for
  # teardown to kill: its process ID may belong to something else by then.
  def wait_within(pid, seconds)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    loop do
      status = collected(pid)
      return status if status
      return nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.02
    end
  end

  def collected(pid)
    _pid, status = Process.wait2(pid, Process::WNOHANG)
    @holders.delete(pid) if status
    status
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

  def start_time(pid) = `TZ=UTC0 LC_ALL=C ps -o lstart= -p #{pid}`.strip

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
    out, _err, _status = run_lock(:checkout, 'sh', '-c', 'umask', umask: 0o022)
    assert_equal 0o600, File.stat(holder_file).mode & 0o777
    assert_equal '0022', out.strip
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
    assert_includes err, 'running: rake [2Jspec .'
    refute_match(/[\e\a]/, err)
  end

  # ps prints a start time in the caller's time zone, so two runs that
  # disagree about the zone must still agree about the holder.
  def test_refuses_a_run_whose_time_zone_differs_from_the_holders
    offsets = %w[America/Chicago Asia/Tokyo].map { |zone| `TZ=#{zone} date +%z` }
    skip 'this machine has no time zone data' if offsets.uniq.size == 1
    pid = hold(:checkout, vars: { 'TZ' => 'America/Chicago' })
    assert_refused(run_lock(:checkout, *mark_ran, vars: { 'TZ' => 'Asia/Tokyo' }), "process #{pid}")
  end

  # Without a `gitdir:` line, or with one naming a directory that is
  # not a git directory, the lock would go wherever the line pointed,
  # and a directory named suite-lock there be taken for a lock left
  # behind. Each case puts an old one where such a lock would be.
  def test_a_git_file_that_names_no_git_directory_is_not_followed
    { '' => '.', "gitdir:\n" => '.', "gitdir:   \n" => '.', "../checkout/.git\n" => '.', "gitdir: .\n" => '.',
      "gitdir: docs\n" => 'docs' }.each do |content, lock_parent|
      %w[HEAD head refs].each do |decoy|
        project = File.join(@scratch, 'archive')
        copy = install_in(project)
        kept = File.join(project, lock_parent, 'suite-lock', 'kept')
        FileUtils.mkdir_p(File.dirname(kept))
        FileUtils.touch(kept)
        File.utime(Time.now - 300, Time.now - 300, File.dirname(kept))
        File.write(File.join(project, lock_parent, decoy), "ref: refs/heads/main\n")
        File.write(File.join(project, '.git'), content)
        _out, err, status = run_script(copy, *mark_ran)
        assert_equal 78, status.exitstatus, "#{content.inspect} beside a file named #{decoy}: #{err}"
        assert File.exist?(kept), content.inspect
        refute File.exist?(ran_log), content.inspect
        FileUtils.rm_rf(project)
      end
    end
  end

  # git still reads a HEAD that is a symbolic link to a branch, and the
  # link stops resolving once the branch's file is packed away.
  def test_takes_the_lock_where_head_is_a_symbolic_link_that_does_not_resolve
    head = File.join(@layouts.fetch(:checkout).common_dir, 'HEAD')
    File.delete(head)
    File.symlink('refs/heads/packed-away', head)
    assert_took_the_lock(run_lock(:nested, 'echo', 'ran'), 'echo ran')
  end

  # A file its owner cannot read is no file to follow. Root reads
  # everything, so there is nothing to test as root.
  def test_a_git_file_or_commondir_that_cannot_be_read_or_is_empty_is_not_followed
    skip 'root can read every file' if Process.uid.zero?
    hold(:checkout)
    commondir = File.join(@layouts.fetch(:outside).git_dir, 'commondir')
    [-> { File.chmod(0o000, commondir) },
     -> { File.chmod(0o644, commondir) && File.write(commondir, '') },
     -> { File.chmod(0o000, File.join(@layouts.fetch(:outside).path, '.git')) }].each_with_index do |damage, index|
      damage.call
      _out, err, status = run_lock(:outside, *mark_ran)
      assert_equal 78, status.exitstatus, "#{index}: #{err}"
      assert_includes err, 'cannot find the git directory', index.to_s
      refute File.exist?(ran_log), index.to_s
    end
  end

  # The holder file is its owner's alone to read, so another user's run
  # finds one it cannot read whenever the lock is held. A holder whose
  # umask is 077 makes a lock directory another user cannot look into
  # at all.
  def test_a_holder_file_or_lock_directory_that_cannot_be_read_is_a_held_lock
    skip 'root can read every file' if Process.uid.zero?
    hold(:checkout)
    [holder_file, lock_dir].each do |closed|
      mode = File.stat(closed).mode
      File.chmod(0o000, closed)
      File.utime(Time.now - 300, Time.now - 300, lock_dir)
      begin
        assert_refused(run_lock(:checkout, *mark_ran), 'cannot read who holds it', lock_dir)
        assert_refused(run_lock(:checkout, '--wait', *mark_ran, within: 5), 'cannot read who holds it')
      ensure
        File.chmod(mode, closed)
      end
    end
  end

  # Puts a command of that name first on every run's PATH, or in `dir`.
  def stand_in(name, body, dir: @fakebin)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, name), "#!/bin/sh\n#{body}\n")
    File.chmod(0o755, File.join(dir, name))
  end

  # A run that went on without a holder file, or with one holding no
  # start time, would be read as gone by every later run.
  def test_gives_the_lock_back_and_stops_when_it_cannot_record_itself_as_the_holder
    { 'ps' => 'ps gave no start time', 'mv' => 'could not be written' }.each do |command, cause|
      stand_in(command, 'exit 1')
      _out, err, status = run_lock(:checkout, *mark_ran)
      assert_equal 73, status.exitstatus, "#{command}: #{err}"
      assert_includes err, cause
      assert_includes err, 'cannot be recorded as the holder'
      refute File.exist?(ran_log), command
      refute File.exist?(lock_dir), command
      FileUtils.rm_f(File.join(@fakebin, command))
    end
  end

  def test_gives_a_taken_over_lock_back_when_it_cannot_record_itself_as_the_holder
    write_holder(pid: dead_pid, start: 'Thu Jan  1 00:00:00 1970')
    stand_in('mv', 'exit 1')
    _out, err, status = run_lock(:checkout, *mark_ran)
    assert_equal 73, status.exitstatus, err
    refute File.exist?(ran_log)
    assert_empty Dir.glob("#{lock_dir}*")
  end

  # A project's documented suite command may run through the lock, and
  # whoever runs it may wrap it again. The inner call is already under
  # the lock, whichever worktree's copy of the script it is.
  def test_a_command_started_under_the_lock_passes_straight_through_it
    inner = "#{script(:nested).shellescape} --wait echo ran"
    out, err, status = run_lock(:checkout, 'sh', '-c', "#{inner}; echo after", within: 10)
    assert_predicate status, :success?, err
    assert_equal "ran\nafter\n", out
    assert_equal "sh -c #{inner}; echo after", File.read(holder_file).split("\n").last
    assert_took_the_lock(run_lock(:checkout, script(:outside), 'echo', 'ran', within: 10),
                         "#{script(:outside)} echo ran")
  end

  # The mark a holder leaves in its environment is believed only while
  # that process holds this lock.
  def test_a_run_carrying_another_holders_mark_is_refused
    pid = hold(:checkout)
    lock = File.realpath(lock_dir)
    ["#{dead_pid} #{lock}", "#{pid} #{lock}-elsewhere", "#{Process.pid} #{lock}", pid.to_s].each do |mark|
      assert_refused(run_lock(:checkout, *mark_ran, vars: { 'SUITE_LOCK_HELD_BY' => mark }), "process #{pid}")
    end
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

  # The other run's takeover ends only once this one has been refused
  # and gone to sleep, which its stand-in sleep marks.
  def test_wait_takes_the_lock_once_another_runs_takeover_is_over
    write_holder(pid: dead_pid, start: 'Thu Jan  1 00:00:00 1970')
    FileUtils.mkdir_p("#{lock_dir}.takeover")
    slept = File.join(@scratch, 'slept')
    waiting = path_with('waiting-bin', 'sleep' => "touch #{slept.shellescape}\nexec /bin/sleep \"$@\"")
    finishing = Thread.new do
      Dir.rmdir("#{lock_dir}.takeover") if wait_for(slept)
    end
    begin
      assert_took_the_lock(run_lock(:checkout, '--wait', 'echo', 'ran', vars: { 'PATH' => waiting }), 'echo ran')
      assert File.exist?(slept), 'the run never waited'
    ensure
      finishing.join
    end
  end

  # A PATH whose first directory holds the given commands.
  def path_with(name, commands)
    dir = File.join(@scratch, name)
    commands.each { |command, body| stand_in(command, body, dir: dir) }
    "#{dir}:#{env.fetch('PATH')}"
  end

  # True once the file is there, false after ten seconds without it.
  def wait_for(path)
    Timeout.timeout(10) { sleep 0.02 until File.exist?(path) }
    true
  rescue Timeout::Error
    false
  end

  # Shell that marks a run as having reached `name` and holds it there
  # until the test lets it go. It also stops holding once the scratch
  # directory is gone, so a test that fails midway leaves no process
  # waiting on a file that can no longer appear.
  def pause_at(name)
    at, go, scratch = ["at-#{name}", "go-#{name}", ''].map { |file| File.join(@scratch, file).shellescape }
    "{ touch #{at}; while [ ! -e #{go} ] && [ -d #{scratch} ]; do sleep 0.05; done; }"
  end

  def reached?(name) = wait_for(File.join(@scratch, "at-#{name}"))
  def let_go(name) = FileUtils.touch(File.join(@scratch, "go-#{name}"))

  # A PATH on which a takeover is terminated by `signal` once it has
  # removed the lock. The stand-in signals its parent, the template,
  # unless that has gone and left it a child of process 1.
  def terminated_by(signal)
    path_with("#{signal}-bin",
              'rm' => "/bin/rm \"$@\"\ncase \"$1\" in -rf) [ \"$PPID\" -gt 1 ] && kill -#{signal} \"$PPID\";; esac")
  end

  def test_a_takeover_ended_by_a_signal_exits_with_that_signals_status_and_leaves_no_takeover_directory
    { 'INT' => 130, 'TERM' => 143, 'HUP' => 129 }.each do |signal, expected|
      write_holder(pid: dead_pid, start: 'Thu Jan  1 00:00:00 1970')
      _out, err, status = run_lock(:checkout, *mark_ran, vars: { 'PATH' => terminated_by(signal) })
      assert_equal expected, status.exitstatus, "#{signal}: #{err}"
      assert_empty Dir.glob("#{lock_dir}*"), signal
      refute File.exist?(ran_log), signal
    end
  end

  # One run is paused on its way into a takeover while another run's
  # takeover is terminated after removing the dead holder's lock, which
  # leaves no lock at all. The paused run goes on and is paused again
  # after it has looked at the lock and before it removes or makes
  # one, and a third run takes the free lock in that moment.
  def test_a_takeover_that_found_no_lock_leaves_one_taken_since
    write_holder(pid: dead_pid, start: 'Thu Jan  1 00:00:00 1970')
    # The pause before `rm -rf` is where a template that removed a lock
    # it had not found would be held while the third run takes it. One
    # that removes nothing there is held at the mkdir that follows.
    paused = path_with('paused-bin',
                       'mkdir' => "case \"$1\" in *.takeover) #{pause_at('takeover')};; " \
                                  "*) [ -e #{File.join(@scratch, 'at-takeover').shellescape} ] && #{pause_at('gap')};; " \
                                  "esac\nexec /bin/mkdir \"$@\"",
                       'rm' => "case \"$1\" in -rf) #{pause_at('gap')};; esac\nexec /bin/rm \"$@\"")
    second = Process.spawn(env.merge('PATH' => paused), script(:checkout), *mark_ran,
                           chdir: @scratch, unsetenv_others: true, err: File::NULL)
    @holders << second
    assert reached?('takeover'), 'the second run never began a takeover'

    _out, err, status = run_lock(:checkout, 'true', vars: { 'PATH' => terminated_by('TERM') })
    assert_equal 143, status.exitstatus, err
    assert_empty Dir.glob("#{lock_dir}*")

    let_go('takeover')
    assert reached?('gap'), 'the second run never reached the lock'
    third = hold(:checkout)
    let_go('gap')

    assert_equal REFUSED, wait_within(second, 10)&.exitstatus
    assert_equal third.to_s, File.read(holder_file).lines.first.strip
    refute File.exist?(ran_log)
  end

  # A run is paused on its way into a takeover of a dead holder's lock.
  # Another run takes that lock over and holds it, and the paused run
  # goes on: it must look at the lock again before removing anything.
  def test_a_takeover_looks_again_at_a_lock_taken_over_while_it_waited
    write_holder(pid: dead_pid, start: 'Thu Jan  1 00:00:00 1970')
    paused = path_with('paused-bin', 'mkdir' => "case \"$1\" in *.takeover) #{pause_at('takeover')};; esac\n" \
                                                'exec /bin/mkdir "$@"')
    second = Process.spawn(env.merge('PATH' => paused), script(:checkout), *mark_ran,
                           chdir: @scratch, unsetenv_others: true, err: File::NULL)
    @holders << second
    assert reached?('takeover'), 'the second run never began a takeover'
    holder = hold(:checkout)
    let_go('takeover')

    assert_equal REFUSED, wait_within(second, 10)&.exitstatus
    assert_equal holder.to_s, File.read(holder_file).lines.first.strip
    refute File.exist?(ran_log)
  end

  # The same, where the lock taken over meanwhile is another user's.
  def test_a_takeover_that_finds_another_users_lock_says_so
    skip 'root can read every file' if Process.uid.zero?
    write_holder(pid: dead_pid, start: 'Thu Jan  1 00:00:00 1970')
    paused = path_with('paused-bin', 'mkdir' => "case \"$1\" in *.takeover) #{pause_at('takeover')};; esac\n" \
                                                'exec /bin/mkdir "$@"')
    errors = File.join(@scratch, 'second.err')
    second = Process.spawn(env.merge('PATH' => paused), script(:checkout), *mark_ran,
                           chdir: @scratch, unsetenv_others: true, err: errors)
    @holders << second
    assert reached?('takeover'), 'the second run never began a takeover'
    hold(:checkout)
    File.chmod(0o000, holder_file)
    let_go('takeover')

    assert_equal REFUSED, wait_within(second, 10)&.exitstatus
    assert_includes File.read(errors), 'cannot read who holds it'
    refute File.exist?(ran_log)
  end

  # Each run that gets the lock ends at once, so the lock changes hands
  # many times while the others look at it. A run that reads a lock in
  # the middle of being replaced must wait like the rest: every one
  # ends with the lock and status 0.
  def test_every_waiting_run_gets_the_lock_while_it_changes_hands
    2.times do |round|
      pids = Array.new(40) do
        Process.spawn(env, script(:checkout), '--wait', 'true', chdir: @scratch, unsetenv_others: true,
                                                                err: File.join(@scratch, 'waiting.err'))
      end
      @holders.concat(pids)
      statuses = pids.map { |pid| wait_within(pid, 120)&.exitstatus }
      assert_equal [0], statuses.uniq, "round #{round}: #{File.read(File.join(@scratch, 'waiting.err'))}"
      assert_empty File.read(File.join(@scratch, 'waiting.err')), "round #{round}"
    end
  end

  # A file where the lock directory belongs is as stale as a directory
  # left behind, and is replaced the same way.
  def test_a_file_left_where_the_lock_belongs_is_taken_over
    FileUtils.touch(lock_dir)
    File.utime(Time.now - 300, Time.now - 300, lock_dir)
    assert_took_the_lock(run_lock(:checkout, '--wait', 'echo', 'ran', within: 10), 'echo ran')
  end

  def test_stops_where_the_git_directory_cannot_be_written_to
    skip 'root can write everywhere' if Process.uid.zero?
    common = @layouts.fetch(:checkout).common_dir
    File.chmod(0o555, common)
    begin
      _out, err, status = run_lock(:checkout, '--wait', *mark_ran, within: 10)
      assert_equal 73, status.exitstatus, err
      assert_includes err, 'cannot be written to'
      refute File.exist?(ran_log)
    ensure
      File.chmod(0o755, common)
    end
  end

  # Eight runs start together against a holder that is gone. Whichever
  # gets the lock keeps it until the other seven have been refused, so
  # a second line in the log means two held it at once.
  def test_only_one_of_many_contenders_takes_over_from_a_dead_holder
    6.times do |round|
      FileUtils.rm_rf(ran_log)
      write_holder(pid: dead_pid, start: 'Thu Jan  1 00:00:00 1970')
      pids = Array.new(8) do
        Process.spawn(env, script(:checkout), 'sh', '-c', "echo ran >> #{ran_log.shellescape}; exec sleep 30",
                      chdir: @scratch, unsetenv_others: true, err: File::NULL)
      end
      @holders.concat(pids)
      refused = refused_among(pids, 7)
      assert_equal [REFUSED] * 7, refused.values, "round #{round}"
      assert wait_for(ran_log), "round #{round}: no run took the lock; statuses #{refused.values}"
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
        status = collected(pid)
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
      assert_includes err, 'mounts the checkout at another path'
      refute File.exist?(ran_log)
    end
  end

  def test_the_stand_in_git_records_a_call
    system(env, 'git', 'status', unsetenv_others: true, out: File::NULL, err: File::NULL)
    assert_equal "status\n", File.read(git_log)
    FileUtils.rm_f(git_log)
  end
end
