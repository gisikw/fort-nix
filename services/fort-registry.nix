{ config, pkgs, lib, ... }:

let
  port = "60452";
  hmacSecretPath = config.age.secrets.hmac_key.path;
  registryKeyPath = config.age.secrets.registry_key.path;

  rubyWithGems = pkgs.ruby.withPackages (ps: with ps; [
    sinatra
    rackup
    puma
  ]);

  script = pkgs.writeText "fort-registry.rb" ''
    require "sinatra"
    require "openssl"
    require "base64"

    set :bind, "0.0.0.0"
    set :port, ${port}

    HMAC_SECRET_PATH = ENV["HMAC_SECRET_PATH"]
    HOSTS_FILE = "/etc/coredns/hosts.conf"

    post "/" do
      timestamp = request.env["HTTP_X_TIMESTAMP"]
      signature = request.env["HTTP_X_SIGNATURE"]
      halt 400, "Missing headers" unless timestamp && signature

      body = request.body.read
      secret = File.read(HMAC_SECRET_PATH).strip
      computed_hmac = Base64.strict_encode64(
        OpenSSL::HMAC.digest("SHA256", secret, body + timestamp)
      )
      halt 403, "Bad HMAC" unless Rack::Utils.secure_compare(computed_hmac, signature)

      decrypted = IO.popen(["age", "-d", "-i", "${registryKeyPath}"], "r+") do |io|
        io.write(body)
        io.close_write
        io.read
      end

      hosts = Hash[File.read(HOSTS_FILE).lines.map { |e| e.strip.split.reverse }]
      hosts.merge!(Hash[decrypted.lines.map { |e| e.strip.split.reverse }])

      File.open(HOSTS_FILE, "w") do |f|
        hosts.each do |host, ip|
          f.puts("#{ip}\t#{host}")
        end
      end

      status 200
    end
  '';
in
{
  networking.firewall.allowedTCPPorts = [ 60452 ];

  age.secrets.hmac_key = {
    file = ../secrets/hmac_key.age;
    owner = "root";
    group = "root";
  };

  age.secrets.registry_key = {
    file = ../secrets/registry_key.age;
    owner = "root";
    group = "root";
  };

  systemd.services.fort-registry = {
    description = "Supports dynamic registration of fort-nix managed hosts";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];

    serviceConfig = {
      ExecStart = "${rubyWithGems}/bin/ruby ${script}";
      Environment = "HMAC_SECRET_PATH=${hmacSecretPath}";
      DynamicUser = false;
    };

    path = [ pkgs.age ];
  };
}
