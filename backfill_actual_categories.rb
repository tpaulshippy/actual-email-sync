#!/usr/bin/env ruby
# frozen_string_literal: true

# Backfill Actual's already-posted uncategorized transactions with Jev.
#
# categorize_transactions.rb only scores the staging DB (spending.db) for
# future posts. This script scores transactions that are already in the
# Actual budget with a null category and writes a JSON mapping that
# apply_actual_categories.js applies via the Actual API (direct SQL edits
# to db.sqlite would not sync to the server).
#
# Categories always come from the live Actual system
# (ActualCategories.spending), never from a hardcoded list.
#
# Usage:
#   export TYPESAFE_API_KEY=...  # https://console.typesafe.ai
#   bundle exec ruby backfill_actual_categories.rb [--dry-run] [--limit N]
#     [--min-confidence 0.6] [--model jev-latest]
#     [--actual-db actual-data/My-Finances-*/db.sqlite]
#     [--out actual_jev_results.json]
require 'optparse'
require 'sqlite3'
require 'json'
require_relative 'lib/actual_categories'
require_relative 'lib/jev_categorizer'

DEFAULT_OUT_PATH = File.expand_path('actual_jev_results.json', __dir__)

options = {
  actual_db: ENV['ACTUAL_BUDGET_DB'],
  limit: nil,
  dry_run: false,
  min_confidence: 0.6,
  model: ENV['JEV_MODEL'] || JevCategorizer::DEFAULT_MODEL,
  out: ENV['JEV_RESULTS_PATH'] || DEFAULT_OUT_PATH
}

OptionParser.new do |opts|
  opts.banner = 'Usage: backfill_actual_categories.rb [options]'
  opts.on('--actual-db=PATH', 'Actual budget db.sqlite path') { |v| options[:actual_db] = v }
  opts.on('--limit=N', Integer, 'Max transactions to score') { |v| options[:limit] = v }
  opts.on('--dry-run', 'Score with Jev but do not write JSON') { options[:dry_run] = true }
  opts.on('--min-confidence=F', Float, 'Skip assignments below this Jev confidence') do |v|
    options[:min_confidence] = v
  end
  opts.on('--model=NAME', 'Jev model (default jev-latest)') { |v| options[:model] = v }
  opts.on('--out=PATH', 'Where to write the JSON mapping') { |v| options[:out] = v }
  opts.on('-h', '--help') do
    puts opts
    exit
  end
end.parse!

UNCATEGORIZED_SQL = <<~SQL
  SELECT id, acct, imported_description, amount, date, notes, category
  FROM transactions
  WHERE tombstone = 0
    AND (category IS NULL OR category = '')
    AND imported_description IS NOT NULL AND imported_description != ''
    AND transferred_id IS NULL
  ORDER BY date
SQL

def parse_notes(notes)
  match = notes.to_s.match(/Source:\s*(\S+)\s*\((.*)\)/)
  return [nil, nil] unless match

  [match[1], match[2]]
end

begin
  categories = ActualCategories.spending(db_path: options[:actual_db])
rescue StandardError => e
  abort "Failed to load categories from Actual: #{e.message}"
end

abort 'No spending categories found in Actual. Create categories in Actual Budget first.' if categories.empty?

puts "Loaded #{categories.length} live Actual categories " \
     "(#{categories.map { |c| c[:name] }.sort.first(5).join(', ')}...)"

actual_path = ActualCategories.budget_db_path(options[:actual_db])
puts "Actual DB: #{actual_path}"

categorizer = JevCategorizer.new(
  categories: categories,
  model: options[:model],
  min_confidence: options[:min_confidence]
)

db = SQLite3::Database.new(actual_path, readonly: true)
db.results_as_hash = true
sql = UNCATEGORIZED_SQL.dup
sql += " LIMIT #{options[:limit].to_i}" if options[:limit]
rows = db.execute(sql)
db.close
puts "Scoring #{rows.length} Actual uncategorized transaction(s) " \
     "with #{options[:model]}#{options[:dry_run] ? ' (dry run)' : ''}..."

results = []
assigned = 0
rows.each do |row|
  amount = row['amount'].to_f / 100.0
  source, subject = parse_notes(row['notes'])
  txn = { 'merchant' => row['imported_description'], 'amount' => amount,
          'transaction_date' => row['date'].to_s,
          'email_subject' => subject, 'source' => source }
  begin
    result = categorizer.categorize_transaction(txn)
  rescue StandardError => e
    puts "  #{row['imported_description']}: ERROR #{e.message}"
    next
  end

  label = result[:category_name] || "SKIP (jev said #{result[:choice].inspect})"
  puts format('  %<merchant>s %<amount>.2f -> %<label>s (conf %<confidence>.2f)',
              merchant: row['imported_description'], amount: amount,
              label: label, confidence: result[:confidence])

  assigned += 1 if result[:category_id]
  results << { id: row['id'], acct: row['acct'], merchant: row['imported_description'],
               amount: amount, date: row['date'], category_id: result[:category_id],
               category_name: result[:category_name], choice: result[:choice],
               confidence: result[:confidence] }
end

if options[:dry_run]
  puts "Done: #{assigned}/#{rows.length} above threshold #{options[:min_confidence]} (dry run, no file written)."
else
  File.write(options[:out], JSON.pretty_generate(results))
  puts "Done: #{assigned}/#{rows.length} above threshold #{options[:min_confidence]}. Wrote #{options[:out]}"
end
