#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests that the three skills which restate the test for whether a
# project has priority labels state it in the same words. The plan-issue
# skill's "Priority label" section owns the rule. The gauntlet,
# finished-issue-housekeeping and architecture-survey skills each carry
# the four-bullet test themselves, because each runs on its own and a
# session running one has no reason to open another skill's file. A
# bullet edited in one skill and not the others would have sessions
# classify the same repository's labels differently with no error
# anywhere. Line wrapping differs between the files, so the comparison
# ignores whitespace. The check does not compare the copies with the
# plan-issue section, which is longer and worded for its own steps.
# Coverage records nothing here: the project measures only bin/*.
# Run: ruby test/priority_label_test_copies_test.rb

require_relative 'cli_test_case'

class PriorityLabelTestCopiesTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  SKILLS = %w[gauntlet finished-issue-housekeeping architecture-survey].freeze
  FIRST = '- **The project declines them**'
  LAST = '- **Otherwise, the project has none.**'
  BULLET_LEADS = [
    '**The project declines them**',
    '**Otherwise, the project states its set**',
    '**Otherwise, the name test:**',
    '**Otherwise, the project has none.**'
  ].freeze

  def test_each_skill_carries_the_four_bullets_in_order
    SKILLS.each do |skill|
      positions = BULLET_LEADS.map { |lead| label_test(skill).index(lead) }

      refute_includes positions, nil, "#{path(skill)} is missing a bullet of the label test"
      assert_equal positions.sort, positions, "#{path(skill)} has the label test's bullets out of order"
    end
  end

  def test_the_three_copies_use_the_same_words
    reference = label_test(SKILLS.first)

    assert_operator reference.size, :>=, 900, "the label test read from #{path(SKILLS.first)} is too short to be whole"
    SKILLS.drop(1).each do |skill|
      assert_equal reference, label_test(skill),
                   "the label test in #{path(skill)} differs from the one in #{path(SKILLS.first)}"
    end
  end

  private

  def label_test(skill)
    text = File.read(File.join(ROOT, path(skill)))
    start = text.index(FIRST) or flunk "#{path(skill)} has no line starting #{FIRST.inspect}"
    last = text.index(LAST, start) or flunk "#{path(skill)} has no line starting #{LAST.inspect}"
    finish = text.index("\n\n", last) || text.size

    text[start...finish].split.join(' ')
  end

  def path(skill)
    "skills/#{skill}/SKILL.md"
  end
end
