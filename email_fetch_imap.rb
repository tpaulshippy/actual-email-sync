#!/usr/bin/env ruby
require 'net/imap'
require 'mail'
require 'json'
require 'time'
require 'addressable/uri'

def decode_subject(encoded)
  return encoded unless encoded
  Addressable::URI.unencode(encoded.gsub(/=\?([^?]+)\?([BQ])\?([^?]*)\?=/) do
    charset = $1
    encoding = $2
    text = $3
    case encoding.upcase
    when 'B'
      [text].pack('M').unpack('m')[0]
    when 'Q'
      text.gsub(/_/, ' ').each_byte.map { |b| b.chr }.join
    else
      text
    end
  end)
end

ACCOUNT = ARGV[0] || abort("Usage: #{$0} <account_email> [date]")
APP_PASSWORD = ENV.fetch('GMAIL_APP_PASSWORD') { abort("Set GMAIL_APP_PASSWORD env var") }
OUTPUT_DIR = File.expand_path('~/email_logs')

target_date = ARGV[1] ? Time.parse(ARGV[1]) : (Time.now - 86400)
yesterday = target_date.strftime('%-d-%b-%Y')

imap = Net::IMAP.new('imap.gmail.com', 993, true)
imap.login(ACCOUNT, APP_PASSWORD)
imap.select('INBOX')

uids = imap.uid_search(['SINCE', yesterday])

uids.each do |uid|
  filepath = File.join(OUTPUT_DIR, "#{uid}.json")
  next if File.exist?(filepath)

  msg = imap.uid_fetch(uid, ['RFC822', 'ENVELOPE'])[0]
  envelope = msg.attr['ENVELOPE']
  raw = msg.attr['RFC822']

  mail = Mail.read_from_string(raw)
  body = mail.text_part&.decoded || mail.body&.decoded

  from_header = envelope.from&.map { |a| "#{a.mailbox}@#{a.host}" }&.join(', ')
  date_header = envelope.date&.to_s
  subject_header = decode_subject(envelope.subject)

  msg_struct = {
    'id' => uid.to_s,
    'body' => body,
    'payload' => {
      'body' => body,
      'headers' => [
        { 'name' => 'From', 'value' => from_header },
        { 'name' => 'Subject', 'value' => subject_header },
        { 'name' => 'Date', 'value' => date_header }
      ]
    }
  }

  File.write(filepath, JSON.pretty_generate({ 'messages' => [msg_struct] }))
end

imap.logout
imap.disconnect
