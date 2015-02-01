require 'net/ssh'
require 'net/ping'
require 'optparse'
require 'YAML'

STDOUT.sync = true
options = {}
config = {}
OptionParser.new do |opts|
    opts.banner = "Usage: failover.rb [options]"
    opts.on("-c", "--config CONFIG", "Configuration file to use. Default is /etc/ec2/config.yml") do |c|
        options[:config] = c
    end
    opts.on("-h", "--host HOST", "Host to check") do |h|
        options[:host] = h
    end
    opts.on("-p", "--port PORT", Integer, "Port to check") do |p|
        options[:port] = p
    end
    opts.on("-r", "--retries RETRIES", Integer, "Number of ping retries") do |r|
        options[:retries] = r
    end
end.parse!

if options[:config]
      $config_file = "#{options[:config]}"
else
      $config_file = "failover.yml"
end
config = YAML.load(File.read($config_file))

unless config["hosts"] && config["options"]["retries"]
  puts 'Use --help, Luke...'
  exit 1
end
def log(message)
  puts "#{Time.now} #{message}"
end
def ping_host(host, port, retries)
  pt = Net::Ping::TCP.new(host, port)
  if ! pt.ping? 
    count = 0
    while count <= retries do 
      log("retrying ##{count}/#{retries}")
      sleep 5
      count += 1
      if pt.ping?
        return 0
        break
      end
      return 1
    end
  else
    return 0
  end
  return 0
end
def save_modified_config(config)
  log("Saving modified config to file...")
  File.open($config_file, 'w') { |f| YAML.dump(config, f) }
end
def promote_host(config, current_master)
  # mark current_master as failed node
  config['hosts'].each do |host|
    if host['host'] == current_master
      log("Marking #{current_master} as a failed node...")
      host['status'] = 'failed'
    end
  end
  # get one node from standby nodes
  log("Sampling a new master node...")
  tmp = config['hosts'].select { |x| x['status'] == 'standby' }.sample
  # promote  it to master
  config['hosts'].each do |host|
    if host['host'] == tmp['host']
      log("Promoted #{host['host']} to be new master...")
      host['status'] = 'master'
    end
  end
  # return new config
  return config
end
def promote_standby_db(config)
  puts config
  master = config['hosts'].select { |x| x['status'] == 'master' }
  `ssh #{master['pg_user']}@#{master['host']} -c 'repmgr -f /etc/repmgr/repmgr.conf standby promote'`
end
def standby_follow(config)
  standbys = config['hosts'].select { |x| x['status'] == 'standby' }
  standbys.each do |host|
    `ssh #{host['pg_user']}@#{host['host']} -c "repmgr -f /etc/repmgr/repmgr.conf standby follow"`
  end
end
def failed_to_slave(config)
  failures = config['hosts'].select { |x| x['status'] == 'failed' }
  master = config['hosts'].select { |x| x['status'] == 'master' }
  counter == 0 
  failures.each do |host|
    pt = ping_host(failures['host'], failures['ssh_port'], config['options']['retries'])
    if pt == 0 
      `ssh #{host['pg_user']}@#{host['host']} -c "repmgr -f /etc/repmgr/repmgr.conf -D #{failures['pg_data']} --force standby clone #{master['host']}"`
      `ssh #{host['pg_user']}@#{host['host']} -c "pg_ctl -D #{failures['pg_data']} start"`
      config['hosts'].each do |ch|
        if ch['host'] == failures['host']
          ch['status'] = 'standby'
          counter += 1
        end
      end
    end
  end
  if counter != 0
    save_modified_config(config)
  end
end
def update_loadbalancer(config)
  log("creating Load balancer config file based on current config")
end

def main(config)
  puts config
  config["hosts"].each do |host|
    if host['status'] == 'master' 
      pt = ping_host(host["host"], host["pg_port"],config['options']['retries'])
      if pt != 0
        log("#{host["host"]} is not working. Starting Failover procedure...")
        config = promote_host(config, host['host'])
        promote_standby_db(config)
        standby_follow(config)
        update_loadbalancer(config)
        save_modified_config(config)
      else
        log("#{host['host']} is aliveee....")
        failed_to_slave(config)
      end
    end
  end
end

main(config)


