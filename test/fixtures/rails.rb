# frozen_string_literal: true

gem "railties", "8.1.1"
gem "actioncable", "8.1.1"
gem "anycable-rails-core", "1.6.2"
gem "puma", "7.1.0"

ENV["RAILS_ENV"] = "test"
ENV["ANYCABLE_HTTP_RPC"] = "true"
ENV["ANYCABLE_BROADCAST_ADAPTER"] = "http"

require "rails"
require "action_cable/engine"
require "anycable/rails"
require "puma"

EVENTS = Queue.new

module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :account

    def connect
      reject_unauthorized_connection unless request.cookies["test_account"] == "42"

      self.account = "42"
    end

    def disconnect
      EVENTS << "disconnect:#{account}"
    end
  end
end

class ChatChannel < ActionCable::Channel::Base
  state_attr_accessor :room

  def subscribed
    return reject unless params[:room].in?([7, 42])

    self.room = params[:room]
    stream_from "room:#{room}"
  end

  def speak(data)
    transmit({"room" => room, "account" => connection.account, "text" => data.fetch("text")})
  end

  def unsubscribed
    EVENTS << "unsubscribe:#{params[:room]}"
  end
end

class CableFixture < Rails::Application
  config.eager_load = false
  config.logger = Logger.new(File::NULL)
  config.secret_key_base = "fixture-only"
  config.action_cable.cable = {"adapter" => "any_cable"}
  config.action_cable.allowed_request_origins = ["http://localhost:3000"]
end

CableFixture.initialize!

app = lambda do |env|
  case env["PATH_INFO"]
  when "/broadcast"
    ActionCable.server.broadcast("room:42", {"text" => "from Rails"})
    [202, {}, []]
  when "/disconnect"
    ActionCable.server.remote_connections.where(account: "42").disconnect(reconnect: false)
    [202, {}, []]
  when "/events"
    events = []
    events << EVENTS.pop until EVENTS.empty?
    [200, {"content-type" => "application/json"}, [JSON.generate(events)]]
  else
    CableFixture.call(env)
  end
end

server = Puma::Server.new(app)
server.add_tcp_listener("127.0.0.1", 0)
puts "RAILS_PORT=#{server.connected_ports.first}"
$stdout.flush
Thread.new { STDIN.read; exit }
server.run.join
