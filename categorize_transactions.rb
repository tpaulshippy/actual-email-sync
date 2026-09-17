#!/usr/bin/env ruby
# frozen_string_literal: true

# Categorize staged email transactions into Actual Budget categories with Jev.
#
# Categories always come from the live Actual system (ActualCategories.load),
# never from a hardcoded list, so renames/additions in Actual flow through.
#
# Usage:
#   export TYPESAFE_API_KEY=...
#   bundle exec ruby categorize_transactions.rb [--dry-run] [--limit N]
#     [--min-confidence 0.6] [--model jev-latest] [--recategorize]
#     [-d spending.db] [--actual-db actual-data/My-Finances-*/db.sqlite]
require 'optparse'
require 'sqlite3'
require 'json'
require_relative 'lib/actual_categories'
require_relative 'lib/jev_categorizer'

DEFAULT_DB_PATH = File.expand_path('spending.db', __dir__)

options = {
  db_path: ENV['SPENDING_DB_PATH'] || DEFAULT_DB_PATH,
  actual_db: ENV['ACTUAL_BUDGET_DB'],
  limit: nil,
  dry_run: false,
  min_confidence: 0.0,
  model: ENV['JEV_MODEL'] || JevCategorizer::DEFAULT_MODEL,
  recategorize: false
}

OptionParser.new do |opts|
  opts.banner = 'Usage: categorize_transactions.rb [options]'
  opts.on('-dPATH', '--db=PATH', 'Staging DB path') { |v| options[:db_path] = v }
  opts.on('--actual-db=PATH', 'Actual budget db.sqlite path') { |v| options[:actual_db] = v }
  opts.on('--limit=N', Integer, 'Max transactions to categorize') { |v| options[:limit] = v }
  opts.on('--dry-run', 'Score with Jev but do not write to DB') { options[:dry_run] = true }
  opts.on('--min-confidence=F', Float, 'Skip assignments below this Jev confidence (default 0)') do |v|
    options[:min_confidence] = v
  end
  opts.on('--model=NAME', 'Jev model (default jev-latest)') { |v| options[:model] = v }
  opts.on('--recategorize', 'Also re-score already-categorized rows') { options[:recategorize] = true }
  opts.on('-h', '--help') do
    puts opts
    exit
  end
end.parse!

CATEGORY_COLUMNS = {
  'category_id' => 'TEXT',
  'category_name' => 'TEXT',
  'category_confidence' => 'REAL',
  'categorized_at' => 'TEXT',
  'category_probabilities' => 'TEXT'
}.freeze

def ensure_category_columns(db)
  cols = db.execute('PRAGMA table_info(transactions)').map { |r| r['COLNAME'] || r['name'] }
  CATEGORY_COLUMNS.each do |name, type|
    db.execute("ALTER TABLE transactions ADD COLUMN #{name} #{type}") unless cols.include?(name)
  end
end

begin
  categories = ActualCategories.spending(db_path: options[:actual_db])
rescue StandardError => e
  abort "Failed to load categories from Actual: #{e.message}"
end

abort 'No spending categories found in Actual. Create categories in Actual Budget first.' if categories.empty?

puts "Loaded #{categories.length} live Actual categories " \
     "(#{categories.map { |c| c[:name] }.sort.first(5).join(', ')}...)"

categorizer = JevCategorizer.new(
  categories: categories,
  model: options[:model],
  min_confidence: options[:min_confidence]
)

db = SQLite3::Database.new(options[:db_path])
db.results_as_hash = true
ensure_category_columns(db)

where = options[:recategorize] ? '1 = 1' : 'category_id IS NULL'
sql = "SELECT * FROM transactions WHERE #{where} ORDER BY id"
sql += " LIMIT #{options[:limit].to_i}" if options[:limit]
rows = db.execute(sql)
puts "Scoring #{rows.length} transaction(s) with #{options[:model]}#{options[:dry_run] ? ' (dry run)' : ''}..."

assigned = 0
skipped = 0
rows.each do |tx|
  begin
    result = categorizer.categorize_transaction(tx)
  rescue StandardError => e
    puts "  ##{tx['id']} #{tx['merchant']}: ERROR #{e.message}"
    skipped += 1
    next
  end

  label = result[:category_name] || "UNCATEGORIZED (jev said #{result[:choice].inspect})"
  puts format('  #%<id>d %<merchant>s %<amount>.2f -> %<label>s (conf %<confidence>.2f)',
              id: tx['id'], merchant: tx['merchant'], amount: tx['amount'].to_f,
              label: label, confidence: result[:confidence])

  next if options[:dry_run]

  if result[:category_id]
    db.execute(
      'UPDATE transactions SET category_id = ?, category_name = ?, ' \
      'category_confidence = ?, categorized_at = CURRENT_TIMESTAMP, ' \
      'category_probabilities = ? WHERE id = ?',
      [result[:category_id], result[:category_name], result[:confidence],
       JSON.generate(result[:probabilities]), tx['id']]
    )
    assigned += 1
  else
    skipped += 1
  end
end

puts "Done: #{assigned} categorized, #{skipped} left uncategorized."
