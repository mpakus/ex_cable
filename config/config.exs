import Config

config :ex_cable, listen: config_env() != :test, production: config_env() == :prod
