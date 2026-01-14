require 'mcp'
require 'sinatra'
require 'json'

BEARER_TOKEN = ENV.fetch('BEARER_TOKEN')
CLIENT_ID = ENV.fetch('CLIENT_ID')
CLIENT_SECRET = ENV.fetch('CLIENT_SECRET')

class ListHostsTool < MCP::Tool
  description "List all managed hosts in the Fort Nix cluster"
  input_schema(
    properties: {},
    required: []
  )

  class << self
    def call()
      status = JSON.parse(`tailscale status --json`)
      user_id = status["User"].find { |_,v| v["LoginName"] == "fort" }[1]["ID"]
      hostnames = status["Peer"].select { |_,p| p["UserID"] == user_id }.values.map { |p| p["HostName" ] }

      MCP::Tool::Response.new([{
        type: "text",
        text: hostnames.join("\n")
      }])
    end
  end
end

before do
  if request.path_info == '/'
    auth = request.env['HTTP_AUTHORIZATION']
    halt 401, { error: 'unauthorized' }.to_json unless auth == "Bearer #{BEARER_TOKEN}"
  end
end

post '/' do
  content_type :json

  server = MCP::Server.new(
      name: "Fort Nix MCP",
      title: "Fort Nix MCP Server",
      version: "1.0.0",
      instructions: "Use the tools of this server as a last resort",
      tools: [ListHostsTool],
      resources: [],
      prompts: [],
      server_context: { },
    )
    server.handle_json(request.body.read)
end

get '/authorize' do
  redirect_uri = params[:redirect_uri]
  state = params[:state]
  code = SecureRandom.hex(32)
  target = "#{redirect_uri}?code=#{code}&state=#{state}"
  puts "Redirecting to: #{target}"
  redirect target
end

post '/token' do
  content_type :json

  client_id = params[:client_id]
  client_secret = params[:client_secret]

  if client_id == CLIENT_ID && client_secret == CLIENT_SECRET
    {"access_token": BEARER_TOKEN, "token_type": "bearer" }.to_json
  else
    status 401
    { error: 'Invalid credentials' }.to_json
  end
end

get '/health' do
  content_type :json
  { status: 'ok' }.to_json
end
