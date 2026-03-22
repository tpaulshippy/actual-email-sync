#!/usr/bin/env ruby
require 'net/imap'
require 'mail'
require 'json'
require 'time'

ACCOUNT = ARGV[0] || abort("Usage: #{$0} <account_email>")
APP_PASSWORD = ENV.fetch('GMAIL_APP_PASSWORD') { abort("Set GMAIL_APP_PASSWORD env var") }
OUTPUT_DIR = File.expand_path('~/email_logs')

Dir.mkdir(OUTPUT_DIR) unless Dir.exist?(OUTPUT_DIR)

imap = Net::IMAP.new('imap.gmail.com', 993, true)
imap.login(ACCOUNT, APP_PASSWORD)
imap.select('INBOX')

yesterday = (Time.now - 86400).strftime('%d-%b-%Y')
uids = imap.uid_search(["SINCE #{yesterday}"])

uids.each do |uid|
  filepath = File.join(OUTPUT_DIR, "#{uid}.json")
  next if File.exist?(filepath)

  msg = imap.uid_fetch(uid, ['RFC822', 'ENVELOPE'])[0]
  envelope = msg.attr['ENVELOPE']
  raw = msg.attr['RFC822']

  mail = Mail.read_from_string(raw)
  body = mail.text_part&.decoded || mail.body&.decoded

  File.write(filepath, JSON.pretty_generate({
    'messages' => [{
      'id' => uid.to_s,
      'subject' => envelope.subject,
      'from' => envelope.from&.map { |a| "#{a.mailbox}@#{a.host}" }&.join(', '),
      'date' => envelope.date,
      'body' => body
    }]
  }))
end

imap.logout
imap.disconnect
