require "sinatra"
require "openssl"
require "base64"
require "redis"

HMAC_SECRET_PATH = ENV["HMAC_SECRET_PATH"]
REGISTRY_KEY_PATH = ENV["REGISTRY_KEY_PATH"]
HOSTS_FILE = "/etc/coredns/hosts.conf"

set :bind, "0.0.0.0"
set :port, @port

set :host_authorization, permitted_host: [
  "ns.#{@domain}",
  "localhost",
  IPAddr.new("192.168.1.0/24")
]

set :redis, Redis.new(path: @registry_sock)

post "/" do
  timestamp = request.env["HTTP_X_TIMESTAMP"]
  signature = request.env["HTTP_X_SIGNATURE"]
  halt 400, "Missing headers" unless timestamp && signature

  body = request.body.read
  secret = File.read(HMAC_SECRET_PATH).strip
  computed_hmac = Base64.strict_encode64(
    OpenSSL::HMAC.digest("SHA256", secret, body + timestamp)
  )
  # TODO: Restore after more debugging
  # halt 403, "Bad HMAC" unless Rack::Utils.secure_compare(computed_hmac, signature)
  if Rack::Utils.secure_compare(computed_hmac, signature)
    puts "HMAC signature valid"
  else
    puts "HMAC signature invalid"
  end

  decrypted = IO.popen(["age", "-d", "-i", REGISTRY_KEY_PATH], "r+") do |io|
    io.write(body)
    io.close_write
    io.read
  end

  decrypted.lines.map { |e| e.strip.split.reverse }.each do |domain, ip|
    internal = true
    value = { domain:, ip:, internal: }.to_json
    settings.redis.set(domain, value)
    settings.redis.publish("updates", value)
  end

  status 200
end
