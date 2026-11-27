#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests that the skills which dispatch sub-agents to read a project carry
# the paragraph that keeps secrets out of those agents' output in the same
# words. Each skill pastes the paragraph into its own sub-agent prompts and
# runs on its own, so it carries its own copy. A copy edited in one skill
# and not the others would leave one skill's agents free to print a file
# the others are told never to show. Line wrapping and quote markers differ
# between the files, so the comparison ignores both.
# Coverage records nothing here: the project measures only bin/*.
# Run: ruby test/secret_paragraph_copies_test.rb

require_relative 'cli_test_case'

class SecretParagraphCopiesTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  SKILLS = %w[gauntlet plan-issue architecture-survey].freeze
  FIRST = "**Never print a secret's value.**"
  LAST = 'for how it is used.'

  def test_the_copies_use_the_same_words
    reference = paragraph(SKILLS.first)

    assert_operator reference.size, :>=, 700, "the paragraph read from #{path(SKILLS.first)} is too short to be whole"
    SKILLS.drop(1).each do |skill|
      assert_equal reference, paragraph(skill),
                   "the secret paragraph in #{path(skill)} differs from the one in #{path(SKILLS.first)}"
    end
  end

  private

  def paragraph(skill)
    text = File.read(File.join(ROOT, path(skill))).gsub(/^\s*>/, ' ').split.join(' ')
    start = text.index(FIRST) or flunk "#{path(skill)} has no paragraph starting #{FIRST.inspect}"
    finish = text.index(LAST, start) or flunk "#{path(skill)} has no #{LAST.inspect} after #{FIRST.inspect}"

    text[start...(finish + LAST.size)]
  end

  def path(skill)
    "skills/#{skill}/SKILL.md"
  end
end
