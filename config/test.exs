import Config

# Tests start the parts they need against their own temporary data dir, so the
# application supervisor stays empty and no listener is opened.
config :junderground, serve: false, data_dir: "tmp/test-data"
