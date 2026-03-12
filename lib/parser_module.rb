require 'base64'
require 'date'

module ParserModule
  def load_parsers(db)
    db.results_as_hash = true
    db.execute("SELECT * FROM email_parsers").map do |row|
      row.transform_keys(&:to_sym)
    end
  end

  def parse_email(body, parser)
    return nil if body.nil? || body.empty?

    decoded_body = nil
    begin
      padding = body.length % 4
      decoded_body = Base64.urlsafe_decode64(body)
    rescue
      return nil
    end

    return nil if decoded_body.nil?

    amount = nil
    merchant = nil
    card_last_four = nil
    transaction_date = nil

    if parser[:amount_pattern]
      match = decoded_body.match(/#{parser[:amount_pattern]}/)
      amount = match[1].gsub(',', '').to_f if match
    end

    if parser[:merchant_pattern]
      match = decoded_body.match(/#{parser[:merchant_pattern]}/)
      merchant = match[1].strip if match
      merchant = merchant.gsub('&apos;', "'") if merchant
    end

    if parser[:card_pattern]
      match = decoded_body.match(/#{parser[:card_pattern]}/)
      card_last_four = match[1] if match
    end

    if parser[:date_pattern]
      match = decoded_body.match(/#{parser[:date_pattern]}/)
      if match
        date_str = match[1]
        mm, dd, yyyy = date_str.split('/')
        transaction_date = "#{yyyy}-#{mm}-#{dd}"
      end
    end

    transaction_date ||= Date.today.strftime('%Y-%m-%d')

    if amount && (merchant || parser[:transaction_type] == 'withdrawal')
      amount = parser[:is_spending].to_i == 1 ? -amount : amount
      {
        amount: amount,
        merchant: merchant || 'Unknown',
        card_last_four: card_last_four,
        transaction_date: transaction_date,
        transaction_type: parser[:transaction_type] || 'posted',
        account: parser[:account]
      }
    else
      nil
    end
  end

  def matches_criteria?(from_val, subject, parser)
    from_val = from_val&.downcase || ''
    subject = subject&.downcase || ''

    from_match = parser[:from_pattern].nil? || from_val.include?(parser[:from_pattern].downcase)
    subject_match = parser[:subject_pattern].nil? || subject.include?(parser[:subject_pattern].downcase)

    from_match && subject_match
  end
end
