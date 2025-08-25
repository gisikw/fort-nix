require 'redis'
require 'json'

HOSTS_FILE = "/etc/coredns/hosts.conf"

@redis = Redis.new(path: @registry_sock)
@domains = {}

def write_domains_to_hostfile
  File.open(HOSTS_FILE, "w") do |f|
    @domains.each do |domain, opts|
      f.puts("#{opts["ip"]}\t#{domain}")
    end
  end
end

i = 0
loop do
  results = @redis.scan(i)
  i = results.first.to_i
  results.last.each do |key|
    @domains[key] = JSON.parse(@redis.get(key))
  end
  break if i == 0
end

write_domains_to_hostfile

@redis.subscribe("updates") do |on|
  on.message do |channel, message|
    puts "Recieved a message"
    value = JSON.parse(message)
    key = value["domain"]
    if @domains[key] != value
      @domains[key] = value
      write_domains_to_hostfile
    end
  end
end
