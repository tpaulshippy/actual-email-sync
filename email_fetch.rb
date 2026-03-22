#!/home/linuxbrew/.linuxbrew/bin/ruby
require 'json'
require 'open3'

ACCOUNT = ARGV[0] || abort("Usage: #{$0} <account_email>")
CONFIG = File.expand_path('~/shared_config')
OUTPUT_DIR = File.expand_path('~/email_logs')

Dir.mkdir(OUTPUT_DIR) unless Dir.exist?(OUTPUT_DIR)

def run_cmd(cmd)
  full = "bash -c \"source #{CONFIG} && #{cmd}\""
  out, err, status = Open3.capture3(full)
  abort "Command failed: #{err}" unless status.success?
  out
end
yesterday = (Time.now - 86400).strftime('%Y/%m/%d')
query = "after:#{yesterday}"
stdout = run_cmd("gog gmail search '#{query}' -j -a #{ACCOUNT}")

result = JSON.parse(stdout)
threads = result['threads'] || []
threads.each do |t|
  id = t['id']
  thread_json = run_cmd("gog gmail thread get #{id} -j -a #{ACCOUNT}")
  thread = JSON.parse(thread_json)
  thread_data = thread['thread'] || thread
  msgs = thread_data['messages'] || []
  msgs.each do |msg|
    msg_id = msg['id']
    filepath = File.join(OUTPUT_DIR, "#{msg_id}.json")
    next if File.exist?(filepath)
    payload = msg['payload'] || {}
    body = payload.dig('body','data')
    if body.nil? || body.empty?
      parts = payload['parts'] || []
      parts.each do |part|
        body = part.dig('body','data')
        break if body && !body.empty?
      end
    end
    msg['body'] = body
    File.write(filepath, JSON.pretty_generate({ 'messages' => [msg] }))
  end
end
