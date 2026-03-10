#!/home/linuxbrew/.linuxbrew/bin/ruby
require 'json'
require 'sqlite3'
require 'base64'
require 'date'
require 'optparse'

DEFAULT_DB_PATH = File.expand_path('~/repos/finance/spending.db')

options = {
  db_path: DEFAULT_DB_PATH
}

OptionParser.new do |opts|
  opts.banner = "Usage: #{$0} [options] <email_file>"

  opts.on("-dPATH", "--db=PATH", "Path to SQLite database") do |path|
    options[:db_path] = path
  end

  opts.on("-h", "--help", "Show this help message") do
    puts opts
    exit
  end
end.parse!

DB_PATH = options[:db_path]

if ARGV.empty?
  puts "Error: Email file path required as argument"
  exit 1
end

EMAIL_FILE = ARGV[0]

def load_parsers(db)
  db.results_as_hash = true
  db.execute("SELECT * FROM email_parsers").map do |row|
    row.transform_keys(&:to_sym)
  end
end

def init_db
  db = SQLite3::Database.new(DB_PATH)
  db.execute(<<-SQL)
    CREATE TABLE IF NOT EXISTS transactions (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      date TEXT,
      merchant TEXT,
      amount REAL,
      card_last_four TEXT,
      source TEXT,
      email_subject TEXT,
      email_file TEXT,
      transaction_type TEXT DEFAULT 'posted',
      account TEXT,
      created_at TEXT DEFAULT CURRENT_TIMESTAMP
    )
  SQL
  db.execute(<<-SQL)
    CREATE TABLE IF NOT EXISTS email_parsers (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      from_pattern TEXT,
      subject_pattern TEXT,
      merchant_pattern TEXT,
      amount_pattern TEXT,
      card_pattern TEXT,
      account_pattern TEXT,
      transaction_type TEXT DEFAULT 'posted',
      account TEXT,
      is_spending INTEGER DEFAULT 1,
      created_at TEXT DEFAULT CURRENT_TIMESTAMP
    )
  SQL
  db
end

def parse_email(body, parser)
  return nil if body.nil? || body.empty?

  begin
    padding = body.length % 4
    body += "=" * (4 - padding) if padding != 0
    body = Base64.urlsafe_decode64(body)
  rescue
    nil
  end

  return nil if body.nil?

  amount = nil
  merchant = nil
  card_last_four = nil

  if parser['amount_pattern']
    match = body.match(/#{parser['amount_pattern']}/)
    amount = match[1].to_f if match
  end

  if parser['merchant_pattern']
    match = body.match(/#{parser['merchant_pattern']}/)
    merchant = match[1].strip if match
    merchant = merchant.gsub('&apos;', "'") if merchant
  end

  if parser['card_pattern']
    match = body.match(/#{parser['card_pattern']}/)
    card_last_four = match[1] if match
  end

  if amount && merchant
    amount = parser[:is_spending].to_i == 1 ? -amount : amount
    {
      amount: amount,
      merchant: merchant,
      card_last_four: card_last_four,
      date: Date.today.strftime('%Y-%m-%d'),
      transaction_type: parser['transaction_type'] || 'posted',
      account: parser['account']
    }
  else
    nil
  end
end

def matches_criteria?(from_val, subject, parser)
  from_val = from_val&.downcase || ''
  subject = subject&.downcase || ''

  from_match = parser['from_pattern'].nil? || from_val.include?(parser['from_pattern'].downcase)
  subject_match = parser['subject_pattern'].nil? || subject.include?(parser['subject_pattern'].downcase)

  from_match && subject_match
end

def process_email_file(filepath, db, parsers)
  file_content = File.read(filepath)
  data = JSON.parse(file_content)

  messages = data['messages'] || data.dig('threads', 0, 'messages') || []
  messages.each do |msg|
      payload = msg['payload'] || {}
      headers = {}
      (payload['headers'] || []).each { |h| headers[h['name']] = h['value'] }

      from_val = headers['From'] || ''
      subject = headers['Subject'] || ''
      body = msg['body']

      parsers.each do |parser|
        if matches_criteria?(from_val, subject, parser)
          parsed = parse_email(body, parser)
          if parsed
            existing = db.get_first_row(
              'SELECT 1 FROM transactions WHERE date = ? AND merchant = ? AND amount = ?',
              [parsed[:date], parsed[:merchant], parsed[:amount]]
            )

             if existing.nil?
               db.execute(
                 'INSERT INTO transactions (date, merchant, amount, card_last_four, source, email_subject, email_file, transaction_type, account) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
                 [parsed[:date], parsed[:merchant], parsed[:amount], parsed[:card_last_four], parser['name'], subject, File.basename(filepath), parsed[:transaction_type], parsed[:account]]
               )
               puts "Added: #{parsed[:date]} - #{parsed[:merchant]} $#{parsed[:amount]} (#{parser['name']}) - #{parsed[:transaction_type]} - #{parsed[:account]}"
             else
               puts "Skipped (duplicate): #{parsed[:merchant]} $#{parsed[:amount]}"
             end
          end
        end
      end
    end
end

parsers = load_parsers(db)
db.results_as_hash = false
process_email_file(EMAIL_FILE, db, parsers)
