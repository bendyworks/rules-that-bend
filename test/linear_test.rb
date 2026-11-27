#!/usr/bin/env ruby
# frozen_string_literal: true

# Golden-master tests for bin/linear's argument handling and pure
# helpers. They pin how every subcommand answers malformed input:
# stray positionals, unknown options, missing option values, repeated
# options, flag-shaped values, and parsing that stays identical whether
# or not POSIXLY_CORRECT is set.
#
# The bin file guards its CLI dispatch behind $PROGRAM_NAME == __FILE__,
# so loading it here exposes the Linear module without executing the
# CLI. Run: ruby test/linear_test.rb

require_relative 'cli_test_case'

# The load runs the module body before any setup scrub can protect it,
# so bin/linear's module body must stay side-effect-free: no env reads,
# no network, nothing but definitions.
load File.expand_path('../bin/linear', __dir__)

# The usage and requiredness checks in every subcommand run before
# Linear::Client is instantiated, and the client's first act is to
# read LINEAR_API_TOKEN. With the token scrubbed, any invocation whose
# argv the parser accepts fails deterministically on this message
# before any network call -- so reaching it proves the parser accepted
# the arguments, and no test ever talks to the real API. It proves
# only that: the identifier-format checks in get/comments run AFTER
# the client is built, so with the token scrubbed a malformed
# identifier also lands here, not on its own message.
TOKEN_MISSING = 'linear: LINEAR_API_TOKEN env var not set'

# Shared across tests so the copies cannot drift from each other;
# still independent literals, never imported from bin/linear.
SEARCH_USAGE = 'Usage: linear search "phrase" [--team KEY] [--limit N] [--json]'
COMMENT_USAGE = 'Usage: linear comment ABC-NNN ("message" | --body TEXT | --body-file PATH)'
COMMENT_EDIT_USAGE = 'Usage: linear comment-edit COMMENT_ID (--body TEXT | --body-file PATH) ' \
                     '(see "linear comments ABC-NNN")'

# Base class: scrubs the Linear-related environment so results do not
# depend on this machine's token, default team, or POSIX parsing mode.
class LinearTestCase < CliTestCase
  def extra_scrubbed_env_keys
    %w[LINEAR_API_TOKEN LINEAR_TEAM_KEY]
  end

  # Defense in depth: the sentinel pins only stay offline while the
  # env scrub holds, and one of them reaches a live commentDelete
  # mutation if it does not. Refuse to run the CLI with a real token
  # present (e.g. a subclass overriding setup without super).
  def guard_cli_invocation(_argv)
    flunk 'LINEAR_API_TOKEN leaked into the test environment' if ENV.key?('LINEAR_API_TOKEN')
  end

  def dispatch_cli(argv)
    Linear::CLI.run(argv)
  end

  # The command's printed output; an abort fails the test with its
  # message rather than ending the run, which Minitest lets SystemExit
  # do.
  def command_output(argv)
    cli_stdout(argv.dup)
  rescue SystemExit => e
    flunk "#{argv.join(' ')} aborted: #{e.message}"
  end

  # Makes Linear::Client.new return +client+ for the rest of the test.
  def stub_client(client)
    Linear::Client.define_singleton_method(:new) { client }
  end

  # Removes stub_client's replacement, so the next test builds the real
  # client. In after_teardown so a subclass's teardown cannot skip it.
  def after_teardown
    stubbed = Linear::Client.singleton_class
    stubbed.send(:remove_method, :new) if stubbed.instance_methods(false).include?(:new)
    super
  end
end

class DispatchTest < LinearTestCase
  def test_no_arguments_prints_usage_without_exiting
    assert_includes cli_stdout([]), 'semantic CLI for Linear'
  end

  def test_help_prints_usage
    assert_includes cli_stdout(['help']), 'semantic CLI for Linear'
  end

  def test_dash_dash_help_prints_usage
    assert_includes cli_stdout(['--help']), 'semantic CLI for Linear'
  end

  def test_dash_h_prints_usage
    assert_includes cli_stdout(['-h']), 'semantic CLI for Linear'
  end

  def test_unknown_subcommand_warns_prints_usage_and_exits_nonzero
    result = abort_result(['bogus-subcommand'])

    assert_equal 1, result.status
    assert_includes result.stderr, 'linear: unknown subcommand "bogus-subcommand"'
    assert_includes result.stdout, 'semantic CLI for Linear'
  end
end

# A positional the subcommand has no slot for means part of the typed
# command was not understood, so every subcommand but comment (whose
# trailing words are the message) and help now rejects one.
class StrayPositionalRejectionsTest < LinearTestCase
  # Every dispatchable subcommand except comment must reject strays --
  # driven from the dispatch table itself, so a subcommand added later
  # cannot silently opt out of the guard by being forgotten here.
  STRAY_EXEMPT = %w[comment].freeze

  (Linear::CLI::COMMANDS.keys - STRAY_EXEMPT).each do |name|
    define_method(:"test_#{name.tr('-', '_')}_rejects_stray_positionals") do
      # Three trailing junk positionals exceed every subcommand's arity
      # (the largest, relate, takes two), so whatever the arity the
      # surplus lands in the stray guard.
      message = abort_message([name, 'x1', 'x2', 'x3'])
      assert_includes message, 'linear: unexpected extra arguments:'
    end
  end

  def test_update_rejects_second_identifier
    # The shape that used to update ABC-1 and drop ABC-2 on the floor.
    assert_equal 'linear: unexpected extra arguments: "ABC-2"', abort_message(%w[update ABC-1 ABC-2 --state Done])
  end

  def test_every_stray_is_listed_and_inspect_quoted
    # Inspect-quoted because a mis-quoted shell line can leave a stray
    # containing spaces, which a bare token would read as two.
    assert_equal 'linear: unexpected extra arguments: "a b", "c"', abort_message(['get', 'ABC-1', 'a b', 'c'])
  end

  def test_comment_keeps_its_trailing_positionals_as_the_message
    # The sole opt-out: reaching the sentinel proves the parser took
    # the trailing words rather than rejecting them.
    assert_equal TOKEN_MISSING, abort_message(%w[comment ABC-1 words of message])
  end

  def test_help_stays_lenient_about_strays
    # Recorded decision, restated here next to the guard it exempts.
    assert_includes cli_stdout(%w[help junk]), 'semantic CLI for Linear'
  end
end

# An option a subcommand does not define is rejected by name rather
# than ignored. Driven from the dispatch table so a subcommand added
# later cannot silently accept unknown flags. --bogus is caught during
# parsing, before any required-flag or positional check, so a bare
# `<cmd> --bogus` reaches the rejection for every subcommand.
class UnknownOptionRejectionsTest < LinearTestCase
  Linear::CLI::COMMANDS.each_key do |name|
    define_method(:"test_#{name.tr('-', '_')}_rejects_unknown_option") do
      # assert_includes, not equal: comment appends its body-shape hint.
      assert_includes abort_message([name, '--bogus']), 'linear: invalid option: --bogus'
    end
  end

  def test_get_suggests_the_near_miss
    # optparse appends its own did-you-mean line for a close match,
    # which is exactly the affordance a typo'd flag wants.
    assert_equal "linear: invalid option: --fulll\nDid you mean?  full",
                 abort_message(%w[get ABC-1 --fulll])
  end

  def test_leading_unknown_flag_is_rejected_not_taken_as_the_identifier
    assert_equal 'linear: invalid option: --unknown', abort_message(%w[get --unknown ABC-1])
  end

  def test_comment_unknown_option_carries_the_body_shape_hint
    assert_equal 'linear: invalid option: --badflag ' \
                 '(comment takes a positional message, --body TEXT, or --body-file PATH)',
                 abort_message(%w[comment ABC-1 --badflag])
  end

  def test_double_dash_terminator_protects_a_dash_leading_search_term
    # The escape hatch for values the leading-dash guard would reject.
    assert_equal TOKEN_MISSING, abort_message(['search', '--', '-not-a-flag'])
  end
end

# Exact usage and validation messages that survive the hardening
# unchanged.
class UsageErrorsTest < LinearTestCase
  def test_get_requires_identifier
    assert_equal 'Usage: linear get ABC-NNN [--full] [--json]', abort_message(['get'])
  end

  def test_comments_requires_identifier
    assert_equal 'Usage: linear comments ABC-NNN [--json]', abort_message(['comments'])
  end

  def test_search_requires_term
    assert_equal SEARCH_USAGE, abort_message(['search'])
  end

  def test_search_rejects_empty_term
    assert_equal SEARCH_USAGE, abort_message(['search', ''])
  end

  def test_search_team_requires_value
    assert_equal 'linear: missing argument: --team', abort_message(%w[search term --team])
  end

  def test_search_limit_requires_integer
    assert_equal 'linear: --limit must be an integer, got "abc"', abort_message(%w[search term --limit abc])
  end

  def test_search_limit_rejects_zero
    # A zero limit asks the API for nothing at all, which is never
    # what the caller meant.
    assert_equal 'linear: --limit must be greater than zero, got "0"', abort_message(%w[search term --limit 0])
  end

  def test_list_limit_rejects_zero
    assert_equal 'linear: --limit must be greater than zero, got "0"',
                 abort_message(%w[list --team ABC --project P --limit 0])
  end

  def test_list_requires_team_when_env_unset
    assert_includes abort_message(['list']), 'Usage: linear list --team KEY'
  end

  def test_list_requires_project_since_or_mine
    assert_includes abort_message(%w[list --team ABC]), 'Usage: linear list --team KEY'
  end

  def test_list_mine_needs_no_project_or_since
    assert_equal TOKEN_MISSING, abort_message(%w[list --team ABC --mine])
  end

  def test_list_since_requires_iso_date
    assert_equal 'linear: --since must be YYYY-MM-DD, got "01-01-2026"',
                 abort_message(%w[list --team ABC --since 01-01-2026])
  end

  def test_list_since_refuses_a_day_the_calendar_lacks
    assert_equal 'linear: --since must be YYYY-MM-DD, got "2026-02-30"',
                 abort_message(%w[list --team ABC --since 2026-02-30])
  end

  # The due date is checked before the client is built, so a bad value
  # fails on its own message and never reaches the token check.
  def test_create_refuses_a_due_date_in_another_form_before_reading_the_token
    assert_equal 'linear: --due must be YYYY-MM-DD, got "12/15/2026"',
                 abort_message(%w[create --team ABC --title T --priority low --no-project --due 12/15/2026])
  end

  def test_create_refuses_due_none
    assert_equal 'linear: --due none clears a due date, which only update can do; pass YYYY-MM-DD',
                 abort_message(%w[create --team ABC --title T --priority low --no-project --due none])
  end

  def test_update_refuses_a_bad_due_date_before_reading_the_token
    assert_equal 'linear: --due must be YYYY-MM-DD or none, got "bogus"',
                 abort_message(%w[update ABC-1 --due bogus])
  end

  def test_create_requires_team_and_title
    assert_includes abort_message(['create']), 'Usage: linear create --team KEY --title TITLE'
  end

  def test_create_requires_priority
    assert_includes abort_message(%w[create --team ABC --title Title]),
                    'linear: --priority is required on create'
  end

  def test_create_requires_project_or_no_project
    assert_includes abort_message(%w[create --team ABC --title Title --priority medium]),
                    'linear: --project is required (or pass --no-project to override).'
  end

  def test_update_requires_identifier
    assert_includes abort_message(['update']), 'Usage: linear update ABC-NNN'
  end

  def test_update_requires_identifier_even_with_flags
    assert_includes abort_message(%w[update --state Done]), 'Usage: linear update ABC-NNN'
  end

  def test_comment_requires_identifier
    assert_equal COMMENT_USAGE, abort_message(['comment'])
  end

  def test_comment_requires_body
    assert_equal COMMENT_USAGE, abort_message(%w[comment ABC-1])
  end

  def test_comment_with_body_but_no_identifier_shows_usage
    assert_equal COMMENT_USAGE, abort_message(%w[comment --body text])
  end

  def test_comment_body_file_must_exist
    assert_equal 'linear: --body-file not found: /nonexistent-battery-file',
                 abort_message(%w[comment ABC-1 --body-file /nonexistent-battery-file])
  end

  def test_comment_edit_body_file_must_be_readable
    Dir.mktmpdir('comment-edit') do |dir|
      assert_equal "linear: --body-file could not be read: #{dir} (Is a directory)",
                   abort_message(['comment-edit', 'some-id', '--body-file', dir])
    end
  end

  def test_comment_edit_body_file_must_be_utf8
    Dir.mktmpdir('comment-edit') do |dir|
      path = File.join(dir, 'latin1.md')
      File.binwrite(path, "caf\xE9 fixed\n".b)
      assert_equal "linear: --body-file is not valid UTF-8: #{path}",
                   abort_message(['comment-edit', 'some-id', '--body-file', path])
    end
  end

  # A UTF-16 mark (Windows Notepad's "Unicode", PowerShell's Out-File)
  # is the usual file in another encoding.
  def test_comment_edit_refuses_a_utf16_body_file
    Dir.mktmpdir('comment-edit') do |dir|
      path = File.join(dir, 'utf16.md')
      File.binwrite(path, "\xFF\xFE".b + "# Fixed\n".encode('UTF-16LE').b)
      assert_equal "linear: --body-file is not valid UTF-8: #{path}",
                   abort_message(['comment-edit', 'some-id', '--body-file', path])
    end
  end

  # A failure Ruby has no Errno class for arrives as a plain
  # SystemCallError, which still gets the plain refusal.
  def test_a_read_failure_with_no_errno_class_gets_a_plain_refusal
    Dir.mktmpdir('comment-edit') do |dir|
      path = File.join(dir, 'body.md')
      File.write(path, "fixed\n")
      File.define_singleton_method(:binread) { |*| raise SystemCallError.new('odd failure', 9999) }
      begin
        # The operating system words the reason ("Unknown error: 9999"
        # on macOS, "Unknown error 9999" on Linux).
        assert_match(/\Alinear: --body-file could not be read: #{Regexp.escape(path)} \(Unknown error:? 9999\)\z/,
                     abort_message(['comment-edit', 'some-id', '--body-file', path]))
      ensure
        File.singleton_class.send(:remove_method, :binread)
      end
    end
  end

  # create reads its --description-file through the same helper and
  # never strips the text, so the check has to come from the helper.
  def test_create_description_file_must_be_utf8
    Dir.mktmpdir('create') do |dir|
      path = File.join(dir, 'latin1.md')
      File.binwrite(path, "caf\xE9\n".b)
      assert_equal "linear: --description-file is not valid UTF-8: #{path}",
                   abort_message(['create', '--team', 'ABC', '--title', 'T', '--priority', 'low',
                                  '--no-project', '--description-file', path])
    end
  end

  # The other file-taking options guard a missing path the same way,
  # rather than letting File.read escape as a raw Errno backtrace.
  def test_create_description_file_must_exist
    assert_equal 'linear: --description-file not found: /nonexistent-battery-file',
                 abort_message(%w[create --team ABC --title T --priority medium --no-project
                                  --description-file /nonexistent-battery-file])
  end

  def test_update_description_file_must_exist
    assert_equal 'linear: --description-file not found: /nonexistent-battery-file',
                 abort_message(%w[update ABC-1 --description-file /nonexistent-battery-file])
  end

  def test_project_create_content_file_must_exist
    assert_equal 'linear: --content-file not found: /nonexistent-battery-file',
                 abort_message(%w[project-create --team ABC --name N --content-file /nonexistent-battery-file])
  end

  def test_project_update_content_file_must_exist
    assert_equal 'linear: --content-file not found: /nonexistent-battery-file',
                 abort_message(%w[project-update --id X --content-file /nonexistent-battery-file])
  end

  def test_comment_delete_requires_id
    assert_equal 'Usage: linear comment-delete COMMENT_ID (see "linear comments ABC-NNN")',
                 abort_message(['comment-delete'])
  end

  def test_comment_edit_requires_id
    assert_equal COMMENT_EDIT_USAGE, abort_message(['comment-edit'])
  end

  def test_comment_edit_with_body_but_no_id_shows_usage
    assert_equal COMMENT_EDIT_USAGE, abort_message(%w[comment-edit --body text])
  end

  def test_comment_edit_refuses_an_empty_id
    assert_equal COMMENT_EDIT_USAGE, abort_message(['comment-edit', '', '--body', 'fixed'])
  end

  def test_comment_edit_refuses_a_blank_id
    assert_equal COMMENT_EDIT_USAGE, abort_message(['comment-edit', '  ', '--body', 'fixed'])
  end

  def test_comment_edit_requires_body
    assert_equal COMMENT_EDIT_USAGE, abort_message(%w[comment-edit some-id])
  end

  def test_comment_edit_refuses_a_blank_body
    assert_equal COMMENT_EDIT_USAGE, abort_message(['comment-edit', 'some-id', '--body', "  \n"])
  end

  def test_comment_edit_refuses_a_blank_body_file
    Dir.mktmpdir('comment-edit') do |dir|
      path = File.join(dir, 'blank.md')
      File.write(path, "\n  \n")
      assert_equal COMMENT_EDIT_USAGE, abort_message(['comment-edit', 'some-id', '--body-file', path])
    end
  end

  def test_comment_edit_body_file_must_exist
    assert_equal 'linear: --body-file not found: /nonexistent-battery-file',
                 abort_message(%w[comment-edit some-id --body-file /nonexistent-battery-file])
  end

  def test_comment_edit_with_id_and_body_reaches_the_client
    assert_equal TOKEN_MISSING, abort_message(%w[comment-edit some-id --body fixed])
  end

  def test_relate_requires_two_identifiers
    assert_equal 'Usage: linear relate ABC-AAA ABC-BBB [--type related|blocks|duplicate] [--json]',
                 abort_message(%w[relate ABC-1])
  end

  def test_project_create_requires_team_and_name
    assert_equal 'Usage: linear project-create --team KEY --name NAME ' \
                 '[--description TEXT] [--content TEXT | --content-file PATH] [--json]',
                 abort_message(%w[project-create --team ABC])
  end

  def test_project_update_requires_id
    assert_equal 'Usage: linear project-update --id PROJECT_ID ' \
                 '[--name NAME] [--description TEXT] [--content TEXT | --content-file PATH] [--json]',
                 abort_message(['project-update'])
  end

  def test_project_update_requires_a_field
    assert_equal 'linear: nothing to update; pass --name, --description, or --content',
                 abort_message(%w[project-update --id X])
  end

  def test_project_update_accepts_a_named_field
    # Landing on the sentinel rather than "nothing to update" is the
    # observable proof that --name's value reached the mutation input,
    # not just that the parser tolerated the flag.
    assert_equal TOKEN_MISSING, abort_message(%w[project-update --id X --name Foo])
  end

  def test_project_list_requires_team_when_env_unset
    assert_equal 'Usage: linear project-list --team KEY [--json] (or set LINEAR_TEAM_KEY)',
                 abort_message(['project-list'])
  end
end

# Repeating a value-taking option used to keep the last value and
# discard the first -- the same dropped-input shape as a stray
# positional, and worse when the surviving value aims the command at
# a different issue or project than the one typed first.
class DuplicateOptionRejectionsTest < LinearTestCase
  def test_search_rejects_duplicate_team
    assert_equal 'linear: duplicate --team', abort_message(%w[search term --team A --team B])
  end

  def test_search_rejects_duplicate_limit
    assert_equal 'linear: duplicate --limit', abort_message(%w[search term --limit 5 --limit 9])
  end

  def test_list_rejects_duplicate_project
    assert_equal 'linear: duplicate --project', abort_message(%w[list --team ABC --project P --project Q])
  end

  def test_project_list_rejects_duplicate_team
    assert_equal 'linear: duplicate --team', abort_message(%w[project-list --team A --team B])
  end

  def test_create_rejects_duplicate_team
    assert_equal 'linear: duplicate --team',
                 abort_message(%w[create --team A --team B --title T --priority medium --no-project])
  end

  def test_update_rejects_duplicate_state
    assert_equal 'linear: duplicate --state', abort_message(%w[update ABC-1 --state A --state B])
  end

  def test_relate_rejects_duplicate_type
    assert_equal 'linear: duplicate --type', abort_message(%w[relate ABC-1 ABC-2 --type blocks --type related])
  end

  def test_project_create_rejects_duplicate_name
    assert_equal 'linear: duplicate --name', abort_message(%w[project-create --team ABC --name X --name Y])
  end

  def test_project_update_rejects_duplicate_name
    assert_equal 'linear: duplicate --name', abort_message(%w[project-update --id X --name A --name B])
  end

  def test_comment_rejects_duplicate_body
    assert_equal 'linear: duplicate --body', abort_message(%w[comment ABC-1 --body a --body b])
  end

  def test_comment_edit_rejects_duplicate_body
    assert_equal 'linear: duplicate --body', abort_message(%w[comment-edit some-id --body a --body b])
  end

  def test_repeating_a_boolean_flag_stays_harmless
    # Deliberately out of scope: a repeated switch discards no input,
    # so there is nothing to protect the user from.
    assert_equal TOKEN_MISSING, abort_message(%w[get ABC-1 --json --json])
  end
end

# The subcommands that already used OptionParser never carried the
# acceptance pattern, so a mandatory-argument option would swallow a
# following flag as its value and act on the misread command.
class FlagShapedValueRejectionsTest < LinearTestCase
  def test_search_team_rejects_flag_shaped_value
    # Every flag is a candidate: --team's value is read by the same
    # parser pass that knows --json and --limit, so neither can be
    # swallowed as a value.
    assert_equal 'linear: invalid argument: --team --limit', abort_message(%w[search term --team --limit 5])
    assert_equal 'linear: invalid argument: --team --json', abort_message(%w[search term --team --json])
  end

  def test_search_team_rejects_single_dash_value
    assert_equal 'linear: invalid argument: --team -x', abort_message(%w[search term --team -x])
  end

  def test_create_rejects_flag_shaped_title
    assert_equal 'linear: invalid argument: --title --json',
                 abort_message(%w[create --team ABC --title --json --priority medium --no-project])
  end

  def test_update_rejects_flag_shaped_state
    assert_equal 'linear: invalid argument: --state --json', abort_message(%w[update ABC-1 --state --json])
  end

  def test_relate_rejects_flag_shaped_type
    assert_equal 'linear: invalid argument: --type --json', abort_message(%w[relate ABC-1 ABC-2 --type --json])
  end

  def test_project_create_rejects_flag_shaped_name
    assert_equal 'linear: invalid argument: --name --json',
                 abort_message(%w[project-create --team ABC --name --json])
  end

  def test_project_update_rejects_flag_shaped_id
    assert_equal 'linear: invalid argument: --id --json', abort_message(%w[project-update --id --json])
  end

  def test_comment_rejects_flag_shaped_body
    assert_equal 'linear: invalid argument: --body --json ' \
                 '(comment takes a positional message, --body TEXT, or --body-file PATH)',
                 abort_message(%w[comment ABC-1 --body --json])
  end

  def test_comment_edit_rejects_flag_shaped_body
    assert_equal 'linear: invalid argument: --body --json', abort_message(%w[comment-edit some-id --body --json])
  end

  # An empty value does not begin with a dash, so the guard must accept
  # it: clearing a field is `--description ''`, and refusing that is a
  # confusing way to fail. Reaching the sentinel proves the parser took
  # the empty value.
  def test_empty_value_is_accepted_not_treated_as_flag_shaped
    assert_equal TOKEN_MISSING, abort_message(['update', 'ABC-1', '--description', ''])
    assert_equal TOKEN_MISSING, abort_message(['update', 'ABC-1', '--title', ''])
    assert_equal TOKEN_MISSING, abort_message(['project-update', '--id', 'X', '--content', ''])
    assert_equal TOKEN_MISSING, abort_message(['search', 'term', '--team', ''])
  end
end

# When a subcommand offers two sources for one value, giving both is
# rejected rather than silently resolved to one.
class ConflictingSourceRejectionsTest < LinearTestCase
  def test_comment_rejects_positional_message_and_body
    assert_equal 'linear: a positional message and --body are mutually exclusive',
                 abort_message(%w[comment ABC-1 hello there --body elsewhere])
  end

  def test_comment_rejects_positional_message_and_body_file
    assert_equal 'linear: a positional message and --body-file are mutually exclusive',
                 abort_message(%w[comment ABC-1 hello --body-file /nonexistent-battery-file])
  end

  def test_comment_rejects_body_and_body_file
    assert_equal 'linear: --body and --body-file are mutually exclusive',
                 abort_message(%w[comment ABC-1 --body inline --body-file /nonexistent-battery-file])
  end

  def test_comment_edit_rejects_body_and_body_file
    assert_equal 'linear: --body and --body-file are mutually exclusive',
                 abort_message(%w[comment-edit some-id --body inline --body-file /nonexistent-battery-file])
  end

  def test_comment_rejects_all_three_message_sources_at_once
    # The only path through the three-way join: a comma-separated list
    # closed with "and", so the rare all-three error still reads cleanly.
    assert_equal 'linear: a positional message, --body, and --body-file are mutually exclusive',
                 abort_message(%w[comment ABC-1 hello --body inline --body-file /nonexistent-battery-file])
  end

  def test_create_rejects_description_inline_and_file
    assert_equal 'linear: --description and --description-file are mutually exclusive',
                 abort_message(%w[create --team ABC --title T --priority low --no-project
                                  --description inline --description-file /nonexistent-battery-file])
  end

  def test_create_rejects_project_and_no_project
    # Contradictory intent: name a project and disclaim one at once.
    assert_equal 'linear: --project and --no-project are mutually exclusive',
                 abort_message(%w[create --team ABC --title T --priority low --project P --no-project])
  end

  def test_update_rejects_description_inline_and_file
    assert_equal 'linear: --description and --description-file are mutually exclusive',
                 abort_message(%w[update ABC-1 --description inline --description-file /nonexistent-battery-file])
  end

  def test_project_create_rejects_content_inline_and_file
    assert_equal 'linear: --content and --content-file are mutually exclusive',
                 abort_message(%w[project-create --team ABC --name N
                                  --content inline --content-file /nonexistent-battery-file])
  end

  def test_project_update_rejects_content_inline_and_file
    assert_equal 'linear: --content and --content-file are mutually exclusive',
                 abort_message(%w[project-update --id X --content inline --content-file /nonexistent-battery-file])
  end
end

# POSIXLY_CORRECT makes OptionParser#parse stop at the first
# positional and strand everything after it. Every subcommand that
# takes an identifier puts flags exactly there, so under #parse a
# machine exporting that variable would see valid flags rejected as
# stray arguments. #permute is immune, and these pin that.
class PosixlyCorrectImmunityTest < LinearTestCase
  # Each shape puts a flag AFTER a positional -- the position where
  # the two parsing modes disagree.
  FLAG_AFTER_POSITIONAL = [
    %w[search term --limit abc],
    %w[get ABC-1 --fulll],
    %w[get ABC-1 --json],
    %w[update ABC-1 ABC-2 --state Done],
    %w[relate ABC-1 ABC-2 ABC-3 --type blocks],
    %w[comment ABC-1 --body a --body b],
    %w[comment-delete some-id --json],
    %w[comment-edit some-id --body a --body b]
  ].freeze

  def test_parsing_is_identical_with_and_without_posixly_correct
    # Each run gets its own copy: Linear::CLI#run shifts the subcommand
    # name off the array it is handed, so a shared literal would reach
    # the next run already missing its first element. (teardown clears
    # POSIXLY_CORRECT; setting it once here keeps the two passes' env
    # handling the same as the single-case tests below.)
    without = FLAG_AFTER_POSITIONAL.map { |argv| abort_message(argv.dup) }
    ENV['POSIXLY_CORRECT'] = '1'
    with = FLAG_AFTER_POSITIONAL.map { |argv| abort_message(argv.dup) }
    FLAG_AFTER_POSITIONAL.each_with_index do |argv, i|
      assert_equal without[i], with[i], "#{argv.inspect} parsed differently under POSIXLY_CORRECT"
    end
  end

  def test_a_flag_after_a_positional_is_still_a_flag
    # Reaching parse_limit proves --limit was read as an option rather
    # than stranded among the positionals. Same shape as the first
    # FLAG_AFTER_POSITIONAL row, pinned here to its absolute message.
    ENV['POSIXLY_CORRECT'] = '1'
    assert_equal 'linear: --limit must be an integer, got "abc"', abort_message(%w[search term --limit abc].dup)
  end

  def test_the_stray_guard_still_sees_only_the_real_stray
    ENV['POSIXLY_CORRECT'] = '1'
    assert_equal 'linear: unexpected extra arguments: "ABC-2"', abort_message(%w[update ABC-1 ABC-2 --state Done].dup)
  end
end

# Pure-helper tests stay on Minitest::Test: they never invoke the CLI,
# so they need neither the env scrub nor the abort capture.
class ListFilterTest < Minitest::Test
  OPEN_STATES = { type: { nin: %w[completed canceled duplicate] } }.freeze

  def test_filters_by_team_and_open_state_alone_by_default
    assert_equal({ team: { key: { eq: 'ABC' } }, state: OPEN_STATES }, Linear.list_filter(team_key: 'ABC'))
  end

  def test_all_includes_finished_issues
    refute Linear.list_filter(team_key: 'ABC', all: true).key?(:state)
  end

  def test_project_and_since_narrow_the_list
    filter = Linear.list_filter(team_key: 'ABC', project_name: 'P', since: '2026-01-02')
    assert_equal({ name: { containsIgnoreCase: 'P' } }, filter[:project])
    assert_equal({ gte: '2026-01-02' }, filter[:createdAt])
  end

  def test_mine_selects_assigned_issues_and_ones_i_filed_with_no_assignee
    me = { isMe: { eq: true } }
    assert_equal({ team: { key: { eq: 'ABC' } }, state: OPEN_STATES,
                   or: [{ assignee: me }, { and: [{ creator: me }, { assignee: { null: true } }] }] },
                 Linear.list_filter(team_key: 'ABC', mine: true))
  end

  def test_without_mine_there_is_no_owner_condition
    refute Linear.list_filter(team_key: 'ABC').key?(:or)
  end
end

# Runs a command against a client that records the query and returns an
# empty page, so a test can read what the command would send to Linear.
class QuerySentTest < LinearTestCase
  QueryRecorder = Struct.new(:graphql, :variables) do
    def query(graphql, variables = {})
      self.graphql = graphql
      self.variables = variables
      { 'data' => { 'issues' => { 'nodes' => [], 'pageInfo' => {} } } }
    end
  end

  # What a check comparing an issue with its pull request reads from --json.
  CHECK_FIELDS = ['state { name type }', 'assignee { name', 'cycle { endsAt }',
                  'attachments { nodes { url title } }', 'branchName'].freeze

  def setup
    @recorder = QueryRecorder.new
    stub_client(@recorder)
  end

  def test_mine_goes_into_the_list_query
    cli_stdout(%w[list --team ABC --mine --json])
    assert_equal Linear.list_filter(team_key: 'ABC', mine: true), @recorder.variables[:filter]
  end

  def test_all_goes_into_the_list_query_beside_mine
    cli_stdout(%w[list --team ABC --mine --all --json])
    assert_equal Linear.list_filter(team_key: 'ABC', mine: true, all: true), @recorder.variables[:filter]
  end

  def test_list_asks_for_what_the_checks_read_and_when_each_issue_changed
    cli_stdout(%w[list --team ABC --mine --json])
    (CHECK_FIELDS + ['updatedAt']).each { |field| assert_includes @recorder.graphql, field }
  end

  def test_list_leaves_out_teammates_email_addresses
    cli_stdout(%w[list --team ABC --mine --json])
    refute_includes @recorder.graphql, 'email'
  end

  def test_get_asks_for_what_the_checks_read
    cli_stdout(%w[get ABC-1 --json])
    CHECK_FIELDS.each { |field| assert_includes @recorder.graphql, field }
  end

  def test_get_asks_for_the_due_date
    cli_stdout(%w[get ABC-1 --json])
    assert_includes @recorder.graphql, 'dueDate'
  end
end

# Runs create and update against a client that answers each query by
# what it asks for and records every call, so a test can read the
# mutation input and the printed summary.
class DueDateSentTest < LinearTestCase
  AnsweringClient = Struct.new(:calls, :due_date) do
    def query(graphql, variables = {})
      calls << [graphql, variables]
      { 'data' => answer(graphql) }
    end

    def resolve_issue(_identifier, fields: 'id')
      { 'id' => 'issue-1', 'identifier' => 'ABC-1', 'team' => { 'id' => 'team-1' }, 'assignee' => nil }
    end

    def mutation_input
      calls.reverse.find { |graphql, _| graphql.include?('mutation') }&.last&.fetch(:input)
    end

    private

    def answer(graphql)
      if graphql.include?('issueCreate') then { 'issueCreate' => { 'success' => true, 'issue' => issue } }
      elsif graphql.include?('issueUpdate') then { 'issueUpdate' => { 'success' => true, 'issue' => issue } }
      elsif graphql.include?('workflowStates')
        { 'workflowStates' => { 'nodes' => [{ 'id' => 'state-1', 'name' => 'Todo', 'type' => 'unstarted' }] } }
      elsif graphql.include?('teams') then { 'teams' => { 'nodes' => [{ 'id' => 'team-1', 'key' => 'ABC' }] } }
      else {}
      end
    end

    def issue
      { 'identifier' => 'ABC-1', 'title' => 'T', 'url' => 'https://example.test/ABC-1',
        'state' => { 'name' => 'Todo' }, 'priorityLabel' => 'Low', 'dueDate' => due_date }
    end
  end

  CREATE = %w[create --team ABC --title T --priority low --no-project].freeze

  def setup
    @client = AnsweringClient.new([], nil)
    stub_client(@client)
  end

  def test_create_sends_the_due_date_and_prints_it
    @client.due_date = '2026-12-15'
    output = command_output(CREATE + %w[--due 2026-12-15])

    assert_equal '2026-12-15', @client.mutation_input[:dueDate]
    assert_includes output, 'Due: 2026-12-15'
  end

  def test_create_without_due_sends_no_due_date
    command_output(CREATE)
    refute @client.mutation_input.key?(:dueDate)
  end

  def test_update_sends_the_due_date
    command_output(%w[update ABC-1 --due 2026-12-20])
    assert_equal '2026-12-20', @client.mutation_input[:dueDate]
  end

  def test_update_due_none_sends_a_null_due_date_to_clear_it
    command_output(%w[update ABC-1 --due none])

    assert @client.mutation_input.key?(:dueDate)
    assert_nil @client.mutation_input[:dueDate]
  end

  # Upper case reaches the mutation as a clear only if update sends what
  # resolve_due_date returns.
  def test_update_summary_shows_a_dash_after_clearing_with_upper_case_none
    output = command_output(%w[update ABC-1 --due NONE])

    assert_nil @client.mutation_input.fetch(:dueDate)
    assert_includes output, 'Due: -'
  end

  def test_update_with_nothing_to_change_lists_every_option_including_due
    assert_equal 'linear: nothing to update; pass --state, --title, --description, --project, --parent, ' \
                 '--assignee, --priority, or --due',
                 abort_message(%w[update ABC-1])
  end

  def test_create_asks_for_the_due_date_back
    command_output(CREATE)
    assert_includes @client.calls.map(&:first).grep(/issueCreate/).first, 'dueDate'
  end

  def test_update_asks_for_the_due_date_back
    command_output(%w[update ABC-1 --title U])
    assert_includes @client.calls.map(&:first).grep(/issueUpdate/).first, 'dueDate'
  end
end

# Runs comment-edit against a client that records the mutation and
# answers it, so a test can read what was sent and what was printed.
class CommentEditSentTest < LinearTestCase
  EditClient = Struct.new(:graphql, :variables, :success, :comment_returned) do
    def query(graphql, variables = {})
      self.graphql = graphql
      self.variables = variables
      comment = { 'id' => variables[:id], 'url' => 'https://example.test/ABC-1#comment-1' }
      { 'data' => { 'commentUpdate' => { 'success' => success, 'comment' => (comment if comment_returned) } } }
    end
  end

  def setup
    @client = EditClient.new(nil, nil, true, true)
    stub_client(@client)
  end

  def test_sends_the_new_body_to_comment_update_for_that_comment
    command_output(%w[comment-edit comment-1 --body fixed])

    assert_includes @client.graphql, 'commentUpdate(id: $id, input: $input)'
    assert_equal({ id: 'comment-1', input: { body: 'fixed' } }, @client.variables)
  end

  # The fake answers success and the URL whatever the query asks for,
  # and Linear answers only what it is asked, so the query itself has
  # to ask.
  def test_asks_for_the_success_flag_and_the_comment_url
    command_output(%w[comment-edit comment-1 --body fixed])

    assert_match(/commentUpdate\([^)]*\)\s*\{[^{]*\bsuccess\b/, @client.graphql)
    assert_match(/\bcomment\s*\{[^}]*\burl\b/, @client.graphql)
  end

  def test_leaves_a_body_files_byte_order_mark_out
    Dir.mktmpdir('comment-edit') do |dir|
      path = File.join(dir, 'bom.md')
      File.binwrite(path, "\xEF\xBB\xBF# Fixed\n".b)
      command_output(['comment-edit', 'comment-1', '--body-file', path])
    end

    assert_equal "# Fixed\n", @client.variables.dig(:input, :body)
  end

  def test_sends_a_body_file_unchanged
    body = "# Fixed\n\n- first line\n  indented line\n"
    Dir.mktmpdir('comment-edit') do |dir|
      path = File.join(dir, 'body.md')
      File.write(path, body)
      command_output(['comment-edit', 'comment-1', '--body-file', path])
    end

    assert_equal body, @client.variables.dig(:input, :body)
  end

  def test_prints_the_edited_comment_url
    assert_equal "Edited comment comment-1: https://example.test/ABC-1#comment-1\n",
                 command_output(%w[comment-edit comment-1 --body fixed])
  end

  def test_an_edit_answered_without_its_comment_aborts
    @client.comment_returned = false
    assert_match(/\Alinear: comment edit failed: /, abort_message(%w[comment-edit comment-1 --body fixed]))
  end

  def test_json_prints_the_response
    output = JSON.parse(command_output(%w[comment-edit comment-1 --body fixed --json]))
    assert_equal 'https://example.test/ABC-1#comment-1', output.dig('data', 'commentUpdate', 'comment', 'url')
  end

  def test_json_prints_a_refused_edit_without_aborting
    @client.success = false
    output = JSON.parse(command_output(%w[comment-edit comment-1 --body fixed --json]))
    assert_equal false, output.dig('data', 'commentUpdate', 'success')
  end

  def test_a_refused_edit_aborts_with_the_response
    @client.success = false
    message = abort_message(%w[comment-edit comment-1 --body fixed])

    assert_match(/\Alinear: comment edit failed: /, message)
    assert_match(/"success" ?=> ?false/, message)
  end
end

class PrintIssueTest < Minitest::Test
  ISSUE = { 'identifier' => 'ABC-1', 'title' => 'T', 'state' => { 'name' => 'Todo' },
            'assignee' => { 'name' => 'Dana' } }.freeze

  def printed(issue)
    out, _err = capture_io { Linear.print_issue(issue, include_comments: false) }
    out
  end

  def test_shows_the_due_date_beside_the_assignee
    assert_includes printed(ISSUE.merge('dueDate' => '2026-12-15')), "Assignee: Dana\nDue: 2026-12-15\n"
  end

  def test_shows_no_due_line_for_an_issue_without_one
    refute_includes printed(ISSUE.merge('dueDate' => nil)), 'Due:'
  end
end

class PureHelpersTest < Minitest::Test
  def test_parse_limit_accepts_base_ten
    assert_equal 25, Linear.parse_limit('25')
  end

  def test_parse_limit_rejects_non_integer
    error = assert_raises(Linear::Error) { Linear.parse_limit('abc') }
    assert_equal 'linear: --limit must be an integer, got "abc"', error.message
  end

  def test_parse_limit_reads_a_leading_zero_as_base_ten
    # Bare Integer() honours the 0 prefix and would read this as 8.
    # Nobody typing --limit 010 means eight.
    assert_equal 10, Linear.parse_limit('010')
  end

  def test_parse_limit_rejects_a_hex_prefix
    error = assert_raises(Linear::Error) { Linear.parse_limit('0x10') }
    assert_equal 'linear: --limit must be an integer, got "0x10"', error.message
  end

  def test_parse_limit_rejects_zero
    error = assert_raises(Linear::Error) { Linear.parse_limit('0') }
    assert_equal 'linear: --limit must be greater than zero, got "0"', error.message
  end

  def test_parse_limit_rejects_a_negative
    error = assert_raises(Linear::Error) { Linear.parse_limit('-5') }
    assert_equal 'linear: --limit must be greater than zero, got "-5"', error.message
  end

  def test_resolve_priority_names_and_case
    assert_equal 3, Linear.resolve_priority('medium')
    assert_equal 1, Linear.resolve_priority('URGENT')
    assert_equal 0, Linear.resolve_priority('none')
  end

  def test_resolve_priority_accepts_digit_strings
    assert_equal 2, Linear.resolve_priority('2')
  end

  def test_resolve_priority_rejects_out_of_range_and_nonsense
    error = assert_raises(Linear::Error) { Linear.resolve_priority('7') }
    assert_equal 'linear: invalid priority "7"; use none|urgent|high|medium|low or 0-4', error.message
    error = assert_raises(Linear::Error) { Linear.resolve_priority('nonsense') }
    assert_equal 'linear: invalid priority "nonsense"; use none|urgent|high|medium|low or 0-4', error.message
  end

  def test_resolve_due_date_returns_an_iso_date_unchanged
    assert_equal '2026-12-15', Linear.resolve_due_date('2026-12-15', allow_none: false)
  end

  def test_resolve_due_date_reads_none_as_clearing_where_allowed
    assert_nil Linear.resolve_due_date('none', allow_none: true)
    assert_nil Linear.resolve_due_date('NONE', allow_none: true)
  end

  def test_resolve_due_date_refuses_none_where_there_is_nothing_to_clear
    error = assert_raises(Linear::Error) { Linear.resolve_due_date('none', allow_none: false) }
    assert_equal 'linear: --due none clears a due date, which only update can do; pass YYYY-MM-DD', error.message
  end

  def test_resolve_due_date_ignores_surrounding_spaces
    assert_equal '2026-12-15', Linear.resolve_due_date(' 2026-12-15 ', allow_none: false)
    assert_nil Linear.resolve_due_date(' none ', allow_none: true)
  end

  def test_resolve_due_date_refuses_another_date_form
    error = assert_raises(Linear::Error) { Linear.resolve_due_date('12/15/2026', allow_none: true) }
    assert_equal 'linear: --due must be YYYY-MM-DD or none, got "12/15/2026"', error.message
  end

  def test_resolve_due_date_refuses_a_day_the_calendar_lacks
    error = assert_raises(Linear::Error) { Linear.resolve_due_date('2026-02-30', allow_none: false) }
    assert_equal 'linear: --due must be YYYY-MM-DD, got "2026-02-30"', error.message
  end
end
