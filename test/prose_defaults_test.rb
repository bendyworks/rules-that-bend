#!/usr/bin/env ruby
# frozen_string_literal: true

# Tests that the gauntlet skill's `prose-defaults` brief names every word
# the guidance lists as a prose default, each in the list of the brief
# meant to carry it. The guidance owns the lists: the metaphor nouns, the
# mental verbs and the adverbs in the Plain language section of
# guidance/code-comments.md, and the title verbs in
# guidance/commit-messages.md. The brief restates them because a team may
# run the gauntlet without importing the guidance, and a word added to
# the guidance and not the brief would go unchecked with no error
# anywhere. The check runs one way: the brief may name more than the
# guidance does. Each list has a minimum size, so a reworded bullet this
# file can no longer read fails here instead of passing on a few words.
# Coverage records nothing here: the project measures only bin/*.
# Run: ruby test/prose_defaults_test.rb

require_relative 'cli_test_case'

class ProseDefaultsTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  CODE_COMMENTS = 'guidance/code-comments.md'
  COMMIT_MESSAGES = 'guidance/commit-messages.md'
  GAUNTLET = 'skills/gauntlet/SKILL.md'
  BRIEF = "the prose-defaults brief in #{GAUNTLET}"

  def test_brief_lists_every_metaphor_noun
    nouns = metaphor_nouns
    list = between(brief, "project's vocabulary (", '); code given', BRIEF)

    assert_operator nouns.size, :>=, 10, too_few(nouns, 'metaphor bullet')
    assert_lists list, nouns, 'metaphor list'
  end

  def test_brief_lists_every_mental_verb
    verbs = mental_verbs
    list = between(brief, 'mental verb (', '); a contrast', BRIEF)

    assert_operator verbs.size, :>=, 4, too_few(verbs, 'mental-verb bullet')
    assert_lists list, verbs, 'mental-verb list'
  end

  def test_brief_lists_every_adverb
    words = adverbs
    list = between(brief, 'an em dash) in one body; ', ' where the mechanism', BRIEF)[/\A[^;]*/]

    assert_operator words.size, :>=, 2, too_few(words, 'adverb bullet')
    assert_lists list, words, 'adverb clause'
  end

  def test_brief_lists_every_title_verb
    verbs = title_verbs
    list = between(brief, 'operator gets (', ', or another verb', BRIEF)

    assert_operator verbs.size, :>=, 5, too_few(verbs, 'title bullets')
    missing = verbs.reject { |verb| list.include?("`#{verb}`") }
    assert_empty missing, "#{BRIEF}: the title list does not name #{missing.join(', ')}"
  end

  private

  def assert_lists(list, words, where)
    missing = words.reject { |word| list.match?(/(?<![\w-])#{Regexp.escape(word)}(?![\w-])/i) }
    assert_empty missing, "#{BRIEF}: the #{where} does not name #{missing.join(', ')}"
  end

  def brief
    @brief ||= between(plain(GAUNTLET), '### Agent: prose-defaults', "### Sorting and fixing Phase 5's findings", GAUNTLET)
  end

  # "...project's vocabulary:** phantom, ghost, ...; twin, ..., latent,
  # "by construction", and "shape" for a kind of thing ("the same shape
  # of bug"). Name the thing itself". Parenthesised examples are dropped,
  # and an item that quotes its term ("shape" for a kind of thing) is
  # read as the quoted term.
  def metaphor_nouns
    list = between(plain(CODE_COMMENTS), "project's vocabulary:**", '. Name the thing itself', CODE_COMMENTS)
    list.gsub(/\([^)]*\)/, '').split(/[,;]/).map { |item| term(item) }.reject(&:empty?)
  end

  def term(item)
    item[/"([^"]+)"/, 1] || item.strip.sub(/\Aand /, '')
  end

  # "**Code does not learn, trust, believe, promise, argue, or overclaim.**"
  def mental_verbs
    list = between(plain(CODE_COMMENTS), '**Code does not ', '.**', CODE_COMMENTS)
    list.split(/,|\bor\b/).map(&:strip).reject(&:empty?)
  end

  # '...never that it happens "silently" or "quietly".**'
  def adverbs
    between(plain(CODE_COMMENTS), 'never that it happens ', '.**', CODE_COMMENTS).scan(/"([^"]+)"/).flatten
  end

  # "...over mechanism verbs (`Add`, `Update`, `Move`)" and "...not what
  # was done to the code.** `Tighten`, ... and `Guard` fail it the way
  # `Add` and `Update` do: ... The outcome verbs above pass it".
  def title_verbs
    text = plain(COMMIT_MESSAGES)
    named = between(text, 'over mechanism verbs (', ')', COMMIT_MESSAGES) +
            between(text, 'not what was done to the code.**', 'The outcome verbs above', COMMIT_MESSAGES)
    named.scan(/`([^`]+)`/).flatten.uniq
  end

  # A tracked file's text with each wrapped line joined to the one before
  # it, and a blockquote's leading `>` dropped, so a brief reads as prose.
  def plain(path)
    File.read(File.join(ROOT, path)).gsub(/\n[> ]*/, ' ')
  end

  def between(text, from, to, source)
    start = text.index(from) or flunk(reworded(from, source))
    start += from.size
    finish = text.index(to, start) or flunk(reworded(to, source))
    text[start...finish]
  end

  def too_few(words, where)
    "read only #{words.inspect} from the #{where} of the guidance: " \
      'the bullet was reworded or its list cut, and this file needs updating to match'
  end

  def reworded(marker, source)
    "#{marker.inspect} is no longer in #{source}: " \
      'that text was reworded, and the markers in this file need updating to match'
  end
end
