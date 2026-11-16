import Config

if config_env() != :test do
  config :junderground,
    port: String.to_integer(System.get_env("PORT") || "4100"),
    data_dir: System.get_env("JG_DATA_DIR") || "data",
    language: System.get_env("JG_LANGUAGE") || "en",
    public_url: System.get_env("JG_PUBLIC_URL") || "http://localhost:4100",
    grant_ttl: String.to_integer(System.get_env("JG_GRANT_TTL") || "900"),
    admin_keys: (System.get_env("JG_ADMIN_KEYS") || "") |> String.split(",", trim: true),
    auto_approve: System.get_env("JG_AUTO_APPROVE") == "1",
    rent_base_fee: String.to_integer(System.get_env("JG_RENT_BASE_FEE") || "0"),
    rent_currency: System.get_env("JG_RENT_CURRENCY") || "CAD",
    rent_block_seconds: String.to_integer(System.get_env("JG_RENT_BLOCK_SECONDS") || "14400"),
    rent_rate_percent:
      (System.get_env("JG_RENT_RATE_PERCENT") || "100,50,25")
      |> String.split(",", trim: true)
      |> Enum.map(&String.to_integer/1),
    turn_urls: (System.get_env("JG_TURN_URLS") || "") |> String.split(",", trim: true),
    turn_secret: System.get_env("JG_TURN_SECRET"),
    sfu_url: System.get_env("JG_SFU_URL"),
    sfu_key: System.get_env("JG_SFU_KEY"),
    sfu_secret: System.get_env("JG_SFU_SECRET"),
    sfu_threshold: String.to_integer(System.get_env("JG_SFU_THRESHOLD") || "5"),
    sfu_token_ttl: String.to_integer(System.get_env("JG_SFU_TOKEN_TTL") || "300"),
    sfu_transport: System.get_env("JG_SFU_TRANSPORT"),
    ws_idle_timeout: String.to_integer(System.get_env("JG_WS_IDLE_TIMEOUT") || "120000")
end
