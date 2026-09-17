# frozen_string_literal: true

require 'base64'
require 'date'

# Regex-based extraction of transactions from bank alert emails.
module ParserModule
  def load_parsers(db)
    db.results_as_hash = true
    db.execute('SELECT * FROM email_parsers').map do |row|
      row.transform_keys(&:to_sym)
    end
  end

  def parse_email(body, parser)
    decoded = decoded_body(body)
    return if decoded.nil?

    fields = extract_fields(decoded, parser)
    return unless fields[:amount] && (fields[:merchant] || parser[:transaction_type] == 'withdrawal')

    assemble_parsed(parser, fields)
  end

  def matches_criteria?(from_val, subject, parser)
    from = from_val&.downcase || ''
    subj = subject&.downcase || ''
    pattern_matches?(from, parser[:from_pattern]) && pattern_matches?(subj, parser[:subject_pattern])
  end

  private

  def decoded_body(body)
    return if body.nil? || body.empty?

    decoded = decode_body(body)
    return if decoded.nil? || decoded.empty?

    decoded
  end

  def decode_body(body)
    Base64.urlsafe_decode64(body)
  rescue StandardError
    body
  end

  def extract_fields(decoded, parser)
    {
      amount: extract_amount(decoded, parser[:amount_pattern]),
      merchant: extract_merchant(decoded, parser[:merchant_pattern]),
      card_last_four: extract_first_match(decoded, parser[:card_pattern]),
      transaction_date: extract_date(decoded, parser[:date_pattern])
    }
  end

  def assemble_parsed(parser, fields)
    amount = parser[:is_spending].to_i == 1 ? -fields[:amount] : fields[:amount]
    {
      amount: amount,
      merchant: fields[:merchant] || 'Unknown',
      card_last_four: fields[:card_last_four],
      transaction_date: fields[:transaction_date],
      transaction_type: parser[:transaction_type] || 'posted',
      account: parser[:account]
    }
  end

  def extract_first_match(text, pattern)
    return if pattern.nil?

    match = text.match(/#{pattern}/)
    match && match[1]
  end

  def extract_amount(text, pattern)
    raw = extract_first_match(text, pattern)
    raw.gsub(',', '').to_f if raw
  end

  def extract_merchant(text, pattern)
    return if pattern.nil? || pattern.empty?

    match = text.match(/#{pattern}/)
    raw = match && match.captures.compact.first
    return if raw.nil?

    raw.strip.gsub('&apos;', "'")
  end

  def extract_date(text, pattern)
    raw = extract_first_match(text, pattern)
    return Date.today.strftime('%Y-%m-%d') if raw.nil?

    mm, dd, yyyy = raw.split('/')
    "#{yyyy}-#{mm}-#{dd}"
  end

  def pattern_matches?(value, pattern)
    pattern.nil? || value.include?(pattern.downcase)
  end
end
