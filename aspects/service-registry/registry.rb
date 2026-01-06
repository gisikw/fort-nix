require 'net/http'
require 'json'

DOMAIN=ENV["DOMAIN"]
FORGE_HOST=ENV["FORGE_HOST"]
BEACON_HOST=ENV["BEACON_HOST"]

SSH_DEPLOY_KEY="/root/.ssh/deployer_ed25519"

def ssh(host, cmd, input = nil)
  IO.popen([
    "ssh",
    "-i", SSH_DEPLOY_KEY,
    "-o", "StrictHostKeyChecking=no",
    "-o", "ConnectTimeout=10",
    "root@#{host}.fort.#{DOMAIN}",
    cmd
  ], "r+") do |io|
    io.write(input) if input
    io.close_write
    io.readlines
  end
end

status = JSON.parse(`tailscale status --json`)
user_id = status["User"].find { |_,v| v["LoginName"] == "fort" }[1]["ID"]
hosts = status["Peer"].select { |_,p| p["UserID"] == user_id }.values.map { |p| p["HostName" ] } | [FORGE_HOST]
host_lan_ip = `ip -4 route get 1.1.1.1`.match(/src\s+(\S+)/)[1]

services = hosts.reduce([]) do |services, host|
  lines = ssh host, "
    (ip -4 -o addr show fortmesh0 2>/dev/null || echo 'NOFORT') | head -n1
    (ip -4 route get #{host_lan_ip} 2>/dev/null || echo 'NOROUTE') | head -n1
    cat /var/lib/fort/host-manifest.json 2>/dev/null || echo '{}'
  "

  vpn_ip = lines[0].split(/\s+/)[3].split("/")[0] rescue 'NOFORT'
  lan_ip = lines[1].match(/src\s+(\S+)/)[1] rescue 'NOROUTE'

  manifest = JSON.parse(lines[2])
  exposed_services = manifest["services"] || []
  services | exposed_services.each do |service|
    service["hostname"] = "#{host}.fort.#{DOMAIN}"
    service["host"] = host
    service["vpn_ip"] = vpn_ip
    service["lan_ip"] = lan_ip
    service["fqdn"] =
      if (service["subdomain"]||"").empty?
        "#{service["name"]}.#{DOMAIN}"
      else
        "#{service["subdomain"]}.#{DOMAIN}"
      end
  end
end

ssh BEACON_HOST, 
  "tee /var/lib/headscale/extra-records.json >/dev/null", 
  services.map { |service|
    {
      name: service["fqdn"],
      type: "A",
      value: service["vpn_ip"]
    }
  }.to_json

ssh FORGE_HOST, 
  "tee /var/lib/coredns/custom.conf >/dev/null", 
  services
    .select { |s| s["visibility"] != "vpn" }
    .map { |s| "#{s["lan_ip"]} #{s["fqdn"]}" }
    .join("\n")

public_vhosts = <<-EOF
# Managed by fort-service-registry

map $http_upgrade $connection_upgrade {
 default upgrade;
 "" close;
}
EOF
services
  .select { |s| s["visibility"] == "public" }
  .each do |service|
    # Always proxy to host nginx (port 443) for consistent SSL/auth handling
    public_vhosts << <<-EOF
    server {
      listen 80;
      listen 443 ssl http2;
      server_name #{service["fqdn"]};

      ssl_certificate     /var/lib/fort/ssl/#{DOMAIN}/fullchain.pem;
      ssl_certificate_key /var/lib/fort/ssl/#{DOMAIN}/key.pem;

      location / {
        proxy_pass https://#{service["vpn_ip"]}:443;
        proxy_set_header Host               $host;
        proxy_set_header Cookie             $http_cookie;
        proxy_set_header X-Forwarded-For    $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto  $scheme;
        proxy_set_header X-Real-IP          $remote_addr;
        proxy_http_version 1.1;
        proxy_set_header Upgrade    $http_upgrade;
        proxy_set_header Connection $connection_upgrade;

        # Validate upstream cert - reject bad traffic at ingress
        proxy_ssl_verify on;
        proxy_ssl_server_name on;
        proxy_ssl_name $host;
        proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;
      }
    }
    EOF
  end
ssh BEACON_HOST,
  "tee /var/lib/fort/nginx/public-services.conf >/dev/null; systemctl reload nginx",
  public_vhosts

def pocket_service_key
  @pocket_service_key ||= File.read("/var/lib/pocket-id/service-key").chomp
end

def get_pocketid_clients
  results = []
  while true do
    uri = URI("https://id.#{DOMAIN}/api/oidc/clients")
    uri.query = URI.encode_www_form({ "pagination[page]" => 2 })
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    request = Net::HTTP::Get.new(uri.request_uri)
    request['X-API-KEY'] = pocket_service_key
    response = JSON.parse(http.request(request).body)
    results |= response["data"]
    break if response["pagination"]["totalPages"] == response["pagination"]["currentPage"]
  end
  results
end

def create_pocketid_client(service)
  uri = URI("https://id.#{DOMAIN}/api/oidc/clients")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.verify_mode = OpenSSL::SSL::VERIFY_NONE
  request = Net::HTTP::Post.new(uri.request_uri)

  request.body = {
    callbackURLs: [],
    credentials: {
      federatedIdentities: []
    },
    isPublic: false,
    logoutCallbackURLs: [],
    name: service["fqdn"],
    pkceEnabled: false,
    requiresReauthentication: false
  }.to_json

  request['X-API-KEY'] = pocket_service_key
  response = JSON.parse(http.request(request).body)

  client_id = response["id"]

  uri = URI("https://id.#{DOMAIN}/api/oidc/clients/#{client_id}/secret")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.verify_mode = OpenSSL::SSL::VERIFY_NONE
  request = Net::HTTP::Post.new(uri.request_uri)
  request['X-API-KEY'] = pocket_service_key
  client_secret = JSON.parse(http.request(request).body)["secret"]

  dir = "/var/lib/fort-auth/#{service["name"]}/"
  ssh service["host"], "cat > #{dir}/client-id && chmod 644 #{dir}/client-id", client_id
  ssh service["host"], "cat > #{dir}/client-secret && chmod 644 #{dir}/client-secret", client_secret

  restart_target = (service["sso"]&.[]("restart") || "oauth2-proxy-#{service["name"]}")
  ssh service["host"], "systemctl restart #{restart_target}"
end

def delete_pocketid_client(client)
  uri = URI("https://id.#{DOMAIN}/api/oidc/clients/#{client["id"]}")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.verify_mode = OpenSSL::SSL::VERIFY_NONE
  request = Net::HTTP::Delete.new(uri.request_uri)
  request['X-API-KEY'] = pocket_service_key
  http.request(request)
end

target_clients = services.reject { |s| s["sso"]["mode"] == "none" rescue true }
current_clients = get_pocketid_clients

clients_to_create =
  target_clients.reject { |c| current_clients.any? { |cc| cc["name"] == c["fqdn"] } }
puts "Creating #{clients_to_create.size} new clients..."
clients_to_create.each { |c| create_pocketid_client(c) }

clients_to_delete =
  current_clients.reject { |cc| target_clients.any? { |c| cc["name"] == c["fqdn"] } }
puts "Deleting #{clients_to_delete.size} orphaned clients..."
clients_to_delete.each { |c| delete_pocketid_client(c) }
