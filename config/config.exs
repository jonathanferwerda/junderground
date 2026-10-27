import Config

# The switch's own identity and limits. Everything here can be overridden at
# runtime by environment variables (config/runtime.exs).
config :junderground,
  serve: true,
  port: 4100,
  data_dir: "data",
  language: "en",
  public_url: "http://localhost:4100",
  grant_ttl: 900,
  admin_keys: [],
  auto_approve: false,
  rent_base_fee: 0,
  rent_currency: "CAD",
  rent_block_seconds: 14_400,
  rent_rate_percent: [100, 50, 25],
  turn_urls: [],
  turn_secret: nil,
  sfu_url: nil,
  sfu_key: nil,
  sfu_secret: nil

import_config "#{config_env()}.exs"
