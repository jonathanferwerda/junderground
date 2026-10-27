import Config

# The switch's own identity and limits. Everything here can be overridden at
# runtime by environment variables (config/runtime.exs).
config :junderground,
  serve: true,
  port: 4100,
  data_dir: "data",
  public_url: "http://localhost:4100",
  grant_ttl: 900,
  turn_urls: [],
  turn_secret: nil,
  sfu_url: nil,
  sfu_key: nil,
  sfu_secret: nil

import_config "#{config_env()}.exs"
