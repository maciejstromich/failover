require 'net/ping'
require 'optparse'
require 'YAML'
require 'erb'

STDOUT.sync = true
options = {}
config = {}
# hack for erb
#master = []
#read_nodes = []
OptionParser.new do |opts|
    opts.banner = "Usage: failover.rb [options]"
    opts.on("-c", "--config CONFIG", "Configuration file to use. Default is /etc/ec2/config.yml") do |c|
        options[:config] = c
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
def get_nodes_by_status(config, status)
  nodes = []
  config['hosts'].each do |host|
    if host['status'] == status
      nodes.push(host)
    end
  end
  if nodes.length == 0
    log("No #{status} found...")
  end
  return nodes
end
def ping_host(host, port, retries, seconds)
  pt = Net::Ping::TCP.new(host, port)
  if ! pt.ping? 
    count = 1
    while count <= retries do 
      log("retrying ##{count}/#{retries}")
      sleep seconds
      count += 1
      if pt.ping?
        return 0
        break
      end
    end
    return 1
  else
    return 0
  end
end
def promote_host(config, current_master)
  # TODO: this method should be rewritten to operate on arrays returned by get_nodes_by_status
  # mark current_master as failed node
  config['hosts'].each do |host|
    if host['host'] == current_master
      log("Marking #{current_master} as a failed node...")
      host['status'] = 'failed'
    end
  end
  # get one node from standby nodes
  log("Sampling a new master node...")
  # TODO: need to check if standby is available and if not then fail it and choose another one
  # promote  it to master
  tmp = config['hosts'].select { |x| x['status'] == 'standby' }.sample
  if ! tmp
    log('ARGH! No standbys to promote...')
    return 1
  else
    config['hosts'].each do |host|
      if host['host'] == tmp['host']
        log("Promoted #{host['host']} to be new master...")
        host['status'] = 'master'
      end
    end
  end
  # return new config
  return config
end
def promote_standby_db(config)
  master = get_nodes_by_status(config, 'master')
  log("ssh #{master[0]['pg_user']}@#{master[0]['host']} -c 'repmgr -f /etc/repmgr/repmgr.conf standby promote'")
end
def standby_follow(config)
  standbys = get_nodes_by_status(config, 'standby')
  if standbys.length == 0
    log('bummer no available standbys')
  else
    standbys.each do |host|
      log("ssh #{host['pg_user']}@#{host['host']} -c \"repmgr -f /etc/repmgr/repmgr.conf standby follow\"")
    end
  end
end
def update_loadbalancer(config)
  read_nodes = []
  master = []
  b = binding
  log("creating Load balancer config file based on current config")
  master = get_nodes_by_status(config, 'master')
  standbys = get_nodes_by_status(config, 'standby')
  template = File.read(config['load_balancer']['template'])
  standbys.each do |standby_node|
    read_nodes.push("#{standby_node['host']}:#{standby_node['pg_port']}")
  end
  render = ERB.new(template)
  File.open(config['load_balancer']['config_path'], 'w') { |f| f.write(render.result b) }
end
def save_modified_config(config)
  log("Saving modified config to file...")
  File.open($config_file, 'w') { |f| YAML.dump(config, f) }
end
def failed_to_slave(config)
  failures = config['hosts'].select { |x| x['status'] == 'failed' }
  master = config['hosts'].select { |x| x['status'] == 'master' }
  counter = 0 
  failures.each do |host|
    pt = ping_host(host['host'], host['ssh_port'], config['options']['retries'], config['options']['seconds'])
    if pt == 0 
      log("ssh #{host['pg_user']}@#{host['host']} -c \"repmgr -f /etc/repmgr/repmgr.conf -D #{host['pg_data']} --force standby clone #{master[0]['host']}\"")
      log("ssh #{host['pg_user']}@#{host['host']} -c \"pg_ctl -D #{host['pg_data']} start\"")
      config['hosts'].each do |ch|
        if ch['host'] == host['host']
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

def main(config)
  master = get_nodes_by_status(config, 'master')
  pt = ping_host(master[0]['host'], master[0]['pg_port'], config['options']['retries'], config['options']['seconds'])
  if pt != 0
    log("#{master[0]['host']} is not working. Starting Failover procedure...")
    config = promote_host(config, master[0]['host'])
    if config == 1
      log("Exiting because not standby nodes are available")
      exit 1
    else
      promote_standby_db(config)
      standby_follow(config)
      update_loadbalancer(config)
      save_modified_config(config)
    end
  else
    log("#{host['host']} is aliveee....")
  end
  failed_to_slave(config)
end

main(config)
