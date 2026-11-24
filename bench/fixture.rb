# frozen_string_literal: true

gem "railties", "8.1.1"
gem "actioncable", "8.1.1"
gem "puma", "7.1.0"

require "rails"
require "action_controller/railtie"
require "action_cable/engine"
require "puma"

rpc = ENV.fetch("BENCH_MODE") == "rpc"
if rpc
  gem "anycable-rails-core", "1.6.2"
  require "anycable/rails"
end

module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :account

    def connect
      reject_unauthorized_connection unless request.cookies["bench"] == "member"
      self.account = "member"
    end
  end
end

class BenchChannel < ActionCable::Channel::Base
  def subscribed
    stream_from params.fetch(:room)
  end
end

class BenchRails < Rails::Application
  config.eager_load = false
  config.logger = Logger.new(File::NULL)
  config.secret_key_base = "local-bench-key"
  config.action_cable.disable_request_forgery_protection = true
end

BenchRails.config.action_cable.cable = {"adapter" => rpc ? "any_cable" : "async"}
BenchRails.initialize!

app = lambda do |env|
  case env.fetch("PATH_INFO")
  when "/healthz"
    [200, {}, ["ready"]]
  when "/_broadcast"
    if env["REQUEST_METHOD"] == "POST" && env["HTTP_AUTHORIZATION"] == "Bearer #{ENV.fetch('ANYCABLE_BROADCAST_KEY')}"
      frame = JSON.parse(env.fetch("rack.input").read)
      ActionCable.server.broadcast(frame.fetch("stream"), JSON.parse(frame.fetch("data")))
      [201, {}, []]
    else
      [401, {}, []]
    end
  else
    BenchRails.call(env)
  end
end

server = Puma::Server.new(app, nil, {min_threads: 5, max_threads: 5})
server.add_tcp_listener("127.0.0.1", Integer(ENV.fetch("PORT")))
server.run.join
