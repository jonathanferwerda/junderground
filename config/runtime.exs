import Config

if config_env() != :test do
  config :junderground,
    port: String.to_integer(System.get_env("PORT") || "4100"),
    data_dir: System.get_env("JG_DATA_DIR") || "data",
    public_url: System.get_env("JG_PUBLIC_URL") || "http://localhost:4100",
    grant_ttl: String.to_integer(System.get_env("JG_GRANT_TTL") || "900"),
    turn_urls: (System.get_env("JG_TURN_URLS") || "") |> String.split(",", trim: true),
    turn_secret: System.get_env("JG_TURN_SECRET"),
    sfu_url: System.get_env("JG_SFU_URL"),
    sfu_key: System.get_env("JG_SFU_KEY"),
    sfu_secret: System.get_env("JG_SFU_SECRET")
end
