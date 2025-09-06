require 'redis'
require 'json'

HOSTS_FILE = "/etc/coredns/hosts.conf"
HAPROXY_FILE = "/var/lib/haproxy/dynamic.cfg"

@redis = Redis.new(path: @registry_sock)
@domains = {}

def write_domains_to_hostfile
  File.open(HOSTS_FILE, "w") do |f|
    @domains.each do |domain, opts|
      f.puts("#{opts["ip"]}\t#{domain}")
    end
  end
end

def write_haproxy_router
  ip_to_domains = @domains.group_by { |_domain, opts| opts["ip"] }

  frontend_entries = []
  backend_entries = []

  ip_to_domains.each_with_index do |(ip, domain_pairs), i|
    backend_name = "backend#{i}"

    domain_pairs.each do |domain, _|
      frontend_entries << "  use_backend #{backend_name} if { req_ssl_sni -i #{domain} }"
    end

    backend_entries << <<~BACKEND
      backend #{backend_name}
        mode tcp
        server #{backend_name}_srv #{ip}:443
    BACKEND
  end

  config = <<~HAPROXY
    frontend https-in
      bind *:443
      tcp-request inspect-delay 5s
      tcp-request content accept if { req_ssl_hello_type 1 }

  #{frontend_entries.join("\n")}

  #{backend_entries.join("\n")}
  HAPROXY

  File.write(HAPROXY_FILE, config)

  if system("systemctl is-active --quiet haproxy")
    puts "Reloading haproxy"
    system("systemctl reload haproxy")
  elsif system("systemctl is-enabled --quiet haproxy")
    puts "Starting haproxy"
    system("systemctl start haproxy")
  else
    puts "haproxy not enabled; skipping"
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
write_haproxy_router

@redis.subscribe("updates") do |on|
  on.message do |channel, message|
    puts "Recieved a message"
    value = JSON.parse(message)
    key = value["domain"]
    if @domains[key] != value
      @domains[key] = value
      write_domains_to_hostfile
      write_haproxy_router
    end
  end
end
