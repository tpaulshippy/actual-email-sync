#!/usr/bin/env ruby
# frozen_string_literal: true

require 'net/imap'
require 'mail'
require 'json'
require 'time'
require 'addressable/uri'

def decode_rfc2047_word(encoding, text)
  case encoding.upcase
  when 'B'
    [text].pack('M').unpack1('m')
  when 'Q'
    text.tr('_', ' ').each_byte.map(&:chr).join
  else
    text
  end
end

def decode_subject(encoded)
  return encoded unless encoded

  Addressable::URI.unencode(encoded.gsub(/=\?([^?]+)\?([BQ])\?([^?]*)\?=/) do
    decode_rfc2047_word(Regexp.last_match(2), Regexp.last_match(3))
  end)
end

ACCOUNT = ARGV[0] || abort('Usage: email_fetch_imap.rb <account_email> [date]')
APP_PASSWORD = ENV.fetch('GMAIL_APP_PASSWORD') { abort('Set GMAIL_APP_PASSWORD env var') }
OUTPUT_DIR = File.expand_path('~/email_logs')

target_date = ARGV[1] ? Time.parse(ARGV[1]) : (Time.now - 86_400)
yesterday = target_date.strftime('%-d-%b-%Y')

imap = Net::IMAP.new('imap.gmail.com', 993, true)
imap.login(ACCOUNT, APP_PASSWORD)
imap.select('INBOX')

uids = imap.uid_search(['SINCE', yesterday])

uids.each do |uid|
  filepath = File.join(OUTPUT_DIR, "#{uid}.json")
  next if File.exist?(filepath)

  msg = imap.uid_fetch(uid, %w[RFC822 ENVELOPE])[0]
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
