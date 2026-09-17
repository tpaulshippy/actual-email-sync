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

def strip_html(html)
  html&.gsub(/<[^>]+>/, ' ')&.gsub(/\s+/, ' ')&.strip
end

def extract_body(mail)
  return mail.body&.decoded unless mail.multipart?

  mail.text_part&.decoded || strip_html(mail.html_part&.decoded)
end

def message_headers(envelope)
  from = envelope.from&.map { |a| "#{a.mailbox}@#{a.host}" }&.join(', ')
  [
    { 'name' => 'From', 'value' => from },
    { 'name' => 'Subject', 'value' => decode_subject(envelope.subject) },
    { 'name' => 'Date', 'value' => envelope.date&.to_s }
  ]
end

def fetch_message(imap, uid)
  msg = imap.uid_fetch(uid, %w[RFC822 ENVELOPE])[0]
  envelope = msg.attr['ENVELOPE']
  mail = Mail.read_from_string(msg.attr['RFC822'])
  body = extract_body(mail)

  msg_struct = {
    'id' => uid.to_s,
    'body' => body,
    'payload' => { 'body' => body, 'headers' => message_headers(envelope) }
  }

  File.write(File.join(OUTPUT_DIR, "#{uid}.json"), JSON.pretty_generate({ 'messages' => [msg_struct] }))
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
  next if File.exist?(File.join(OUTPUT_DIR, "#{uid}.json"))

  fetch_message(imap, uid)
end

imap.logout
imap.disconnect
