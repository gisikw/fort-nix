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

# Proxy management has been migrated to the control plane
# See: fort.host.capabilities.proxy-configure (public-ingress)
#      fort.host.needs.proxy.* (consumers)

# OIDC client management has been migrated to the control plane
# See: fort.host.capabilities.oidc-register (pocket-id)
#      fort.host.needs.oidc-register.* (consumers)
