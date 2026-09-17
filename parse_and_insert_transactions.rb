#!/home/linuxbrew/.linuxbrew/bin/ruby
# frozen_string_literal: true

require 'json'
require 'sqlite3'
require 'base64'
require 'date'
require 'optparse'
require_relative 'lib/parser_module'

DEFAULT_DB_PATH = File.expand_path('~/repos/finance/spending.db')

TRANSACTIONS_TABLE_SQL = <<~SQL
  CREATE TABLE IF NOT EXISTS transactions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    transaction_date TEXT,
    merchant TEXT,
    amount REAL,
    card_last_four TEXT,
    source TEXT,
    email_subject TEXT,
    email_file TEXT,
    transaction_type TEXT DEFAULT 'posted',
    account TEXT,
    matched_auth_id INTEGER,
    matched_posted_id INTEGER,
    actual_posted INTEGER DEFAULT 0,
    created_at TEXT DEFAULT CURRENT_TIMESTAMP
  )
SQL

EMAIL_PARSERS_TABLE_SQL = <<~SQL
  CREATE TABLE IF NOT EXISTS email_parsers (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    from_pattern TEXT,
    subject_pattern TEXT,
    merchant_pattern TEXT,
    amount_pattern TEXT,
    card_pattern TEXT,
    account_pattern TEXT,
    date_pattern TEXT,
    transaction_type TEXT DEFAULT 'posted',
    account TEXT,
    is_spending INTEGER DEFAULT 1,
    matches_auth_on_card INTEGER DEFAULT 0,
    created_at TEXT DEFAULT CURRENT_TIMESTAMP
  )
SQL

TRANSACTION_FLAGS_TABLE_SQL = <<~SQL
  CREATE TABLE IF NOT EXISTS transaction_flags (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    transaction_id INTEGER,
    type TEXT NOT NULL,
    status TEXT DEFAULT 'open',
    description TEXT,
    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
    resolved_at TEXT,
    FOREIGN KEY(transaction_id) REFERENCES transactions(id)
  )
SQL

DUPLICATE_CHECK_SQL = 'SELECT 1 FROM transactions ' \
                      'WHERE transaction_date = ? AND merchant = ? AND amount = ?'

AUTH_MATCH_SQL = <<~SQL
  SELECT id, merchant FROM transactions
  WHERE transaction_type = ? AND amount = ? AND card_last_four = ? AND matched_posted_id IS NULL
  ORDER BY transaction_date DESC, id DESC LIMIT 1
SQL

INSERT_TRANSACTION_SQL = 'INSERT INTO transactions (transaction_date, merchant, amount, card_last_four, ' \
                         'source, email_subject, email_file, transaction_type, account, matched_auth_id) ' \
                         'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)'

INSERT_FLAG_SQL = 'INSERT INTO transaction_flags (transaction_id, type, status, description) ' \
                  'VALUES (?, ?, ?, ?)'

# Per-email context threaded through the parse/record helpers.
ParseContext = Struct.new(:filepath, :parser, :subject, :from, :body)

options = {
  db_path: DEFAULT_DB_PATH
}

OptionParser.new do |opts|
  opts.banner = 'Usage: parse_and_insert_transactions.rb [options] <email_file>'

  opts.on('-dPATH', '--db=PATH', 'Path to SQLite database') do |path|
    options[:db_path] = path
  end

  opts.on('-h', '--help', 'Show this help message') do
    puts opts
    exit
  end
end.parse!

DB_PATH = options[:db_path]

# Top-level include is intentional: this is a script, not a class.
include ParserModule # rubocop:disable Style/MixinUsage

if ARGV.empty?
  puts 'Error: Email file path required as argument'
  exit 1
end

EMAIL_FILE = ARGV[0]

def init_db
  db = SQLite3::Database.new(DB_PATH)
  db.execute(TRANSACTIONS_TABLE_SQL)
  db.execute(EMAIL_PARSERS_TABLE_SQL)
  db.execute(TRANSACTION_FLAGS_TABLE_SQL)
  db
end

def process_email_file(filepath, db, parsers)
  data = JSON.parse(File.read(filepath))
  messages = data['messages'] || data.dig('threads', 0, 'messages') || []
  messages.each { |msg| process_message(msg, filepath, db, parsers) }
end

def process_message(msg, filepath, db, parsers)
  from_val, subject = message_headers(msg)
  parsers.each do |parser|
    context = ParseContext.new(filepath, parser, subject, from_val, msg['body'])
    try_parser(db, context)
  end
end

def message_headers(msg)
  payload = msg['payload'] || {}
  headers = {}
  (payload['headers'] || []).each { |h| headers[h['name']] = h['value'] }
  [headers['From'] || '', headers['Subject'] || '']
end

def try_parser(db, context)
  return unless matches_criteria?(context.from, context.subject, context.parser)

  parsed = parse_email(context.body, context.parser)
  record_parsed_transaction(db, parsed, context) if parsed
end

def record_parsed_transaction(db, parsed, context)
  if duplicate_transaction?(db, parsed)
    puts duplicate_summary(parsed)
    return
  end

  matched_auth_id, unmatched = find_matching_authorization(db, context.parser, parsed)
  insert_transaction(db, parsed, context, matched_auth_id)
  flag_unmatched_posted(db, parsed) if unmatched
  puts added_summary(context, parsed)
end

def duplicate_transaction?(db, parsed)
  !db.get_first_row(
    DUPLICATE_CHECK_SQL,
    [parsed[:transaction_date], parsed[:merchant], parsed[:amount]]
  ).nil?
end

def insert_transaction(db, parsed, context, matched_auth_id)
  db.execute(
    INSERT_TRANSACTION_SQL,
    [parsed[:transaction_date], parsed[:merchant], parsed[:amount], parsed[:card_last_four],
     context.parser[:name], context.subject, File.basename(context.filepath),
     parsed[:transaction_type], parsed[:account], matched_auth_id]
  )
end

def duplicate_summary(parsed)
  "Skipped (duplicate): #{parsed[:merchant]} $#{parsed[:amount]}"
end

def added_summary(context, parsed)
  "Added: #{parsed[:transaction_date]} - #{parsed[:merchant]} $#{parsed[:amount]} " \
    "(#{context.parser[:name]}) - #{parsed[:transaction_type]} - #{parsed[:account]}"
end

def find_matching_authorization(db, parser, parsed)
  return [nil, false] unless parser[:matches_auth_on_card] == 1 && parsed[:card_last_four]

  auth_match = db.get_first_row(
    AUTH_MATCH_SQL,
    ['authorization', parsed[:amount], parsed[:card_last_four]]
  )
  return apply_auth_match(db, auth_match, parsed) if auth_match

  puts "WARNING: No matching authorization found for $#{parsed[:amount]} " \
       "on card #{parsed[:card_last_four]}"
  [nil, true]
end

def apply_auth_match(db, auth_match, parsed)
  matched_auth_id = auth_match.is_a?(Hash) ? auth_match['id'] : auth_match[0]
  parsed[:merchant] = auth_match.is_a?(Hash) ? auth_match['merchant'] : auth_match[1]
  db.execute('UPDATE transactions SET matched_posted_id = ? WHERE id = ?', [0, matched_auth_id])
  puts "Matched to authorization ##{matched_auth_id}: #{parsed[:merchant]}"
  [matched_auth_id, false]
end

def flag_unmatched_posted(db, parsed)
  tx_id = db.last_insert_row_id
  db.execute(
    INSERT_FLAG_SQL,
    [tx_id, 'unmatched_posted', 'open',
     "No matching authorization for $#{parsed[:amount]} on card #{parsed[:card_last_four]}"]
  )
end

db = init_db
parsers = load_parsers(db)
db.results_as_hash = false
process_email_file(EMAIL_FILE, db, parsers)
