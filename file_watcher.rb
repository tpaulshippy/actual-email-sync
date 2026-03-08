#!/home/linuxbrew/.linuxbrew/bin/ruby
require 'json'
require 'listen'
require 'optparse'
require 'fileutils'

DEFAULT_CONFIG_PATH = File.expand_path('~/repos/finance/watcher_scripts.json')

options = {
  config_path: DEFAULT_CONFIG_PATH
}

OptionParser.new do |opts|
  opts.banner = "Usage: #{$0} [options]"

  opts.on("-cPATH", "--config=PATH", "Path to watcher scripts config JSON file") do |path|
    options[:config_path] = path
  end

  opts.on("-h", "--help", "Show this help message") do
    puts opts
    exit
  end
end.parse!

CONFIG_PATH = options[:config_path]

def load_config
  JSON.parse(File.read(CONFIG_PATH))
end

def execute_scripts(filepath, scripts)
  scripts.each do |script|
    command = script['command']
    args = script['args'] || []
    
    # Replace {filepath} placeholder with actual filepath
    args = args.map { |arg| arg.gsub('{filepath}', filepath) }
    
    full_command = "#{command} #{args.join(' ')}"
    
    puts "Executing: #{full_command}"
    
    begin
      system(full_command)
      if $?.success?
        puts "✓ Script executed successfully"
      else
        puts "✗ Script failed with exit code #{$?.exitstatus}"
      end
    rescue => e
      puts "✗ Error executing script: #{e.message}"
    end
  end
end

config = load_config
watchers = config['watchers'] || []

if watchers.empty?
  puts "Error: No watchers configured in #{CONFIG_PATH}"
  exit 1
end

listeners = []

watchers.each do |watcher|
  watch_dir = File.expand_path(watcher['watch_dir'])
  file_pattern = watcher['file_pattern'] || '*.json'
  scripts = watcher['scripts'] || []
  
  unless Dir.exist?(watch_dir)
    puts "Warning: Watch directory does not exist: #{watch_dir}"
    next
  end
  
  if scripts.empty?
    puts "Warning: No scripts configured for #{watch_dir}"
    next
  end
  
  puts "Watching #{watch_dir} for files matching #{file_pattern}..."
  
  listener = Listen.to(watch_dir, only: /#{file_pattern}$/) do |modified, added, removed|
    (modified + added).each do |filepath|
      sleep 1
      execute_scripts(filepath, scripts)
    end
  end
  
  listeners << listener
end

if listeners.empty?
  puts "Error: No valid watchers configured"
  exit 1
end

puts "Starting file watchers..."
listeners.each(&:start)

puts "Press Ctrl+C to stop..."

sleep
