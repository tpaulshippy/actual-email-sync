#!/usr/bin/env ruby
# frozen_string_literal: true

require 'minitest/autorun'
require 'sqlite3'
require 'json'
require 'tmpdir'
require 'fileutils'
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
    assert(cats.none? { |c| c[:name].nil? || c[:name].empty? })
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

  def test_state_includes_day_of_week_for_iso_date
    c = JevCategorizer.new(categories: sample_categories)
    state = c.state_for('merchant' => 'CHIPOTLE 0658', 'transaction_date' => '2026-09-17')
    assert_equal 'Thursday', state[:day_of_week]
  end

  def test_state_includes_day_of_week_for_actual_yyyymmdd
    c = JevCategorizer.new(categories: sample_categories)
    assert_equal 'Monday', c.state_for('merchant' => 'X', 'transaction_date' => '20260504')[:day_of_week]
    assert_equal 'Monday', c.state_for('merchant' => 'X', 'transaction_date' => 20_260_504)[:day_of_week]
  end

  def test_state_omits_day_of_week_when_date_unusable
    c = JevCategorizer.new(categories: sample_categories)
    assert_nil c.state_for('merchant' => 'X')['day_of_week']
    refute_includes c.state_for('merchant' => 'X', 'transaction_date' => 'not a date'),
                    :day_of_week
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

# Fixture-backed coverage for ActualCategories that runs everywhere, including
# CI where the real (gitignored) Actual db.sqlite is absent. Builds a miniature
# Actual-shaped budget DB in a tmpdir and drives the same load path.
class TestActualCategoriesFixture < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @db_path = File.join(@dir, 'db.sqlite')
    build_mini_actual_db(@db_path)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_load_reads_categories_from_db
    cats = ActualCategories.load(db_path: @db_path)
    assert_equal %w[Coffee Coffee Groceries Income Phones], cats.map { |c| c[:name] }.sort
    assert(cats.all? { |c| c[:id] && c[:name] && c[:group] })
  end

  def test_load_excludes_hidden_and_tombstoned
    cats = ActualCategories.load(db_path: @db_path)
    names = cats.map { |c| c[:name] }
    refute_includes names, 'Old Hidden'
    refute_includes names, 'Deleted'
  end

  def test_spending_excludes_income
    cats = ActualCategories.spending(db_path: @db_path)
    assert(cats.none? { |c| c[:is_income] })
    assert_includes cats.map { |c| c[:name] }, 'Groceries'
  end

  def test_to_criteria_disambiguates_duplicate_names
    cats = ActualCategories.spending(db_path: @db_path)
    criteria = ActualCategories.to_criteria(cats)
    assert_equal cats.length, criteria.length
    assert_includes criteria.keys, 'Discretionary > Coffee'
    assert_includes criteria.keys, 'Usual Expenses > Coffee'
  end

  def test_find_by_choice_handles_disambiguated_form
    cats = ActualCategories.spending(db_path: @db_path)
    found = ActualCategories.find_by_choice(cats, 'Usual Expenses > Coffee')
    assert_equal 'cat-usual-coffee', found[:id]
  end

  private

  def build_mini_actual_db(path)
    db = SQLite3::Database.new(path)
    db.execute('CREATE TABLE category_groups (id TEXT PRIMARY KEY, name TEXT, tombstone INTEGER DEFAULT 0)')
    db.execute(<<~SQL)
      CREATE TABLE categories (
        id TEXT PRIMARY KEY, name TEXT, is_income INTEGER DEFAULT 0,
        cat_group TEXT, sort_order REAL, tombstone INTEGER DEFAULT 0,
        hidden BOOLEAN NOT NULL DEFAULT 0
      )
    SQL
    db.execute("INSERT INTO category_groups (id, name) VALUES ('g-usual', 'Usual Expenses')")
    db.execute("INSERT INTO category_groups (id, name) VALUES ('g-disc', 'Discretionary')")
    db.execute("INSERT INTO category_groups (id, name) VALUES ('g-inc', 'Income')")
    seed = [
      ['cat-groceries', 'Groceries', 0, 'g-usual', 0, 0],
      ['cat-phones', 'Phones', 0, 'g-usual', 0, 0],
      ['cat-usual-coffee', 'Coffee', 0, 'g-usual', 0, 0],
      ['cat-disc-coffee', 'Coffee', 0, 'g-disc', 0, 0],
      ['cat-income', 'Income', 1, 'g-inc', 0, 0],
      ['cat-hidden', 'Old Hidden', 0, 'g-usual', 1, 0],
      ['cat-deleted', 'Deleted', 0, 'g-usual', 0, 1]
    ]
    seed.each do |id, name, income, group, hidden, tombstone|
      db.execute('INSERT INTO categories (id, name, is_income, cat_group, hidden, tombstone) VALUES (?, ?, ?, ?, ?, ?)',
                 [id, name, income, group, hidden, tombstone])
    end
    db.close
  end
end
