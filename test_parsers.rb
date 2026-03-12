#!/usr/bin/env ruby
require 'minitest/autorun'
require 'sqlite3'
require_relative 'lib/parser_module'

class TestLoadParsers < Minitest::Test
  include ParserModule

  def test_load_parsers_returns_symbol_keys
    db = SQLite3::Database.new(':memory:')
    db.execute("CREATE TABLE email_parsers (id INTEGER, name TEXT, from_pattern TEXT, subject_pattern TEXT, merchant_pattern TEXT, amount_pattern TEXT, card_pattern TEXT, account_pattern TEXT, date_pattern TEXT, transaction_type TEXT, account TEXT, is_spending INTEGER DEFAULT 1, matches_auth_on_card INTEGER DEFAULT 0)")
    db.execute("INSERT INTO email_parsers (name, from_pattern, subject_pattern, matches_auth_on_card) VALUES ('test_parser', 'test@example.com', 'test subject', 1)")

    parsers = load_parsers(db)

    assert_equal 1, parsers.length
    parser = parsers.first
    assert parser.key?(:name), "Parser should have symbol key :name"
    assert parser.key?(:from_pattern), "Parser should have symbol key :from_pattern"
    assert parser.key?(:matches_auth_on_card), "Parser should have symbol key :matches_auth_on_card"
    refute parser.key?('name'), "Parser should NOT have string key 'name'"
    refute parser.key?('matches_auth_on_card'), "Parser should NOT have string key 'matches_auth_on_card'"
  end
end

class TestMatchesCriteria < Minitest::Test
  include ParserModule

  def test_matches_criteria_with_symbol_keys
    parser = {
      from_pattern: 'fidelityealerts',
      subject_pattern: 'debit posted',
      matches_auth_on_card: 1
    }

    result = matches_criteria?('fidelityealerts@example.com', 'Fidelity Card Debit Posted', parser)

    assert result, "Should match when from and subject patterns match"
  end

  def test_matches_criteria_demonstrates_original_bug
    parser = {
      from_pattern: 'fidelityealerts',
      subject_pattern: 'debit posted',
      matches_auth_on_card: 1
    }

    string_key_access = parser[:from_pattern]
    assert_equal 'fidelityealerts', string_key_access, "Symbol key should work"
    assert_equal 1, parser[:matches_auth_on_card], "Symbol key should return value"

    string_key_access_wrong = parser['from_pattern']
    assert_nil string_key_access_wrong, "String key should return nil (this is the bug)"
  end

  def test_matches_criteria_nil_patterns
    parser = {
      from_pattern: nil,
      subject_pattern: nil,
      matches_auth_on_card: 1
    }

    result = matches_criteria?('any@example.com', 'any subject', parser)

    assert result, "Should match when patterns are nil"
  end

  def test_matches_criteria_partial_match_fails
    parser = {
      from_pattern: 'fidelityealerts',
      subject_pattern: 'debit posted',
    }

    result = matches_criteria?('other@example.com', 'Fidelity Card Debit Posted', parser)

    refute result, "Should NOT match when from pattern doesn't match"
  end
end

class TestParseEmail < Minitest::Test
  include ParserModule

  def test_parse_email_extracts_merchant_with_symbol_key
    body = Base64.urlsafe_encode64("charged $102.35 at TOTAL *WIRELESS SVCS")
    parser = {
      merchant_pattern: 'charged\\s+\\$\\d+\\.\\d+\\s+at\\s+(.+?)$',
      amount_pattern: 'charged\\s+\\$(\\d+\\.\\d+)',
      transaction_type: 'authorization',
      is_spending: 1
    }

    result = parse_email(body, parser)

    assert_equal 'TOTAL *WIRELESS SVCS', result[:merchant]
    assert_equal -102.35, result[:amount]
  end

  def test_parse_email_extracts_card_last_four
    body = Base64.urlsafe_encode64("ending in 6730 amount 100")
    parser = {
      merchant_pattern: '(.+)',
      amount_pattern: 'amount (\\d+)',
      card_pattern: 'ending in (\\d{4})',
      transaction_type: 'authorization',
      is_spending: 1,
      account: nil
    }

    result = parse_email(body, parser)

    assert_equal '6730', result[:card_last_four]
  end
end

class TestAuthMatchingCondition < Minitest::Test
  include ParserModule

  def test_auth_matching_runs_with_symbol_key
    parser = { matches_auth_on_card: 1 }
    parsed = { card_last_four: '6730' }

    should_run = parser[:matches_auth_on_card] == 1 && parsed[:card_last_four]

    assert should_run, "Authorization matching should run when matches_auth_on_card=1 and card present"
  end

  def test_auth_matching_skips_with_string_key
    parser = { 'matches_auth_on_card' => 1 }
    parsed = { card_last_four: '6730' }

    should_run = parser[:matches_auth_on_card] == 1 && parsed[:card_last_four]

    refute should_run, "Authorization matching should NOT run with string key (this was the bug)"
  end

  def test_auth_matching_skips_when_flag_is_zero
    parser = { matches_auth_on_card: 0 }
    parsed = { card_last_four: '6730' }

    should_run = parser[:matches_auth_on_card] == 1 && parsed[:card_last_four]

    refute should_run, "Should skip matching when matches_auth_on_card is 0"
  end

  def test_auth_matching_skips_without_card
    parser = { matches_auth_on_card: 1 }
    parsed = { card_last_four: nil }

    should_run = parser[:matches_auth_on_card] == 1 && parsed[:card_last_four]

    refute should_run, "Should skip matching when card_last_four is nil"
  end
end
