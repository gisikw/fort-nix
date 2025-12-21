require 'json-schema'

# Force Reader to always accept files/URIs from nix store
class JSON::Schema::Reader
  def accept_file?(pathname)
    true
  end

  def accept_uri?(uri)
    true
  end
end

require_relative 'server'

run Sinatra::Application
