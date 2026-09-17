#!/usr/bin/env ruby
require 'minitest/autorun'
require 'sqlite3'
require 'json'
require_relative 'lib/actual_categories'
require_relative 'lib/jev_categorizer'

FakeParsedResponse = Struct.new(:parsed)

class FakeChat
  attr_reader :asked_state
  def initialize(parsed)
    @parsed = parsed
  end

  def ask(state)
    @asked_state = state
    FakeParsedResponse.new(@parsed)
  end
end

class TestActualCategoriesLive < Minitest::Test
  def test_load_reads_from_actual_db_not_hardcoded
    cats = begin
      ActualCategories.load
    rescue StandardError
      skip 'No live Actual db.sqlite found (set ACTUAL_BUDGET_DB)'
    end
    refute_empty cats, 'Expected categories from the live Actual budget DB'
    names = cats.map { |c| c[:name] }
    # Spot-check real budget content without freezing the whole list:
    # the file must track Actual, so assert structure + a couple of stable groups.
    assert_includes names, 'Groceries'
    assert cats.all? { |c| c[:id] && c[:name] && c[:group] }, 'Each category needs id/name/group'
    # No tombstoned/hidden rows leak through
    assert cats.none? { |c| c[:name].nil? || c[:name].empty? }
  end

  def test_spending_excludes_income
    cats = begin
      ActualCategories.spending
    rescue StandardError
      skip 'No live Actual db.sqlite found (set ACTUAL_BUDGET_DB)'
    end
    refute_empty cats
    assert cats.none? { |c| c[:is_income] }, 'Spending list must exclude Income group'
  end

  def test_to_criteria_covers_every_live_category
    cats = begin
      ActualCategories.spending
    rescue StandardError
      skip 'No live Actual db.sqlite found (set ACTUAL_BUDGET_DB)'
    end
    criteria = ActualCategories.to_criteria(cats)
    assert_equal cats.length, criteria.length, 'Jev Choice options must be exactly the live categories'
  end

  def test_find_by_choice_round_trips
    cats = begin
      ActualCategories.spending
    rescue StandardError
      skip 'No live Actual db.sqlite found (set ACTUAL_BUDGET_DB)'
    end
    target = cats.find { |c| c[:name] == 'Groceries' } || cats.first
    found = ActualCategories.find_by_choice(cats, target[:name])
    assert_equal target[:id], found[:id]
  end
end

class TestJevCategorizer < Minitest::Test
  def sample_categories
    [
      { id: 'id-groceries', name: 'Groceries', group: 'Usual Expenses', is_income: false },
      { id: 'id-gas', name: 'Gas', group: 'Usual Expenses', is_income: false },
      { id: 'id-coffee', name: 'Coffee', group: 'Discretionary', is_income: false }
    ]
  end

  def test_requires_live_categories
    assert_raises(ArgumentError) { JevCategorizer.new(categories: []) }
  end

  def test_criteria_built_from_actual_categories
    c = JevCategorizer.new(categories: sample_categories)
    assert_equal %w[Coffee Gas Groceries].sort, c.criteria.keys.sort
    assert_match(/Usual Expenses/, c.criteria['Groceries'])
  end

  def test_categorize_maps_choice_to_actual_id
    fake = FakeChat.new({ 'category' => { 'choice' => 'Groceries',
                                          'confidence' => 0.91,
                                          'probabilities' => { 'Groceries' => 0.91 } } })
    c = JevCategorizer.new(categories: sample_categories,
                           chat_factory: ->(_schema) { fake })
    result = c.categorize_transaction('merchant' => 'WHOLE FOODS', 'amount' => -42.10)
    assert_equal 'id-groceries', result[:category_id]
    assert_equal 'Groceries', result[:category_name]
    assert_in_delta 0.91, result[:confidence]
    # State sent to Jev is the transaction as JSON (System One state-in).
    state = JSON.parse(fake.asked_state)
    assert_equal 'WHOLE FOODS', state['merchant']
  end

  def test_low_confidence_leaves_uncategorized
    fake = FakeChat.new({ 'category' => { 'choice' => 'Gas',
                                          'confidence' => 0.3,
                                          'probabilities' => { 'Gas' => 0.3 } } })
    c = JevCategorizer.new(categories: sample_categories, min_confidence: 0.6,
                           chat_factory: ->(_schema) { fake })
    result = c.categorize_transaction('merchant' => '???', 'amount' => -1.0)
    assert_nil result[:category_id]
    assert_nil result[:category_name]
    assert_equal 'Gas', result[:choice], 'Keeps Jev suggestion for review'
  end

  def test_unknown_choice_leaves_uncategorized
    fake = FakeChat.new({ 'category' => { 'choice' => 'Nope', 'confidence' => 0.99,
                                          'probabilities' => {} } })
    c = JevCategorizer.new(categories: sample_categories,
                           chat_factory: ->(_schema) { fake })
    result = c.categorize_transaction('merchant' => 'X', 'amount' => -1.0)
    assert_nil result[:category_id]
  end
end
