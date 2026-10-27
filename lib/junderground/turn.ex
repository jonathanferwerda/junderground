defmodule Junderground.Turn do
  @moduledoc """
  Time-limited TURN credentials in coturn's `use-auth-secret` form.

  The shared secret never leaves the server: the client gets
  `username = "<expiry>:<subject>"` and `credential = base64(HMAC-SHA1(secret,
  username))`, which coturn validates without a lookup. With no secret or no
  URLs configured this returns `[]` — media then has to connect directly or
  through an SFU, which is the normal path on a tailnet.
  """

  @default_ttl 600

  def credentials(subject, ttl \\ @default_ttl) do
    urls = Application.get_env(:junderground, :turn_urls, [])
    secret = Application.get_env(:junderground, :turn_secret)

    cond do
      urls in [nil, []] ->
        []

      not is_binary(secret) or byte_size(secret) < 16 ->
        []

      true ->
        ttl = if is_integer(ttl) and ttl > 0, do: ttl, else: @default_ttl
        expires = System.system_time(:second) + ttl
        username = "#{expires}:#{subject}"
        credential = :crypto.mac(:hmac, :sha, secret, username) |> Base.encode64()

        [
          %{
            "urls" => urls,
            "username" => username,
            "credential" => credential,
            "expires" => expires
          }
        ]
    end
  end
end
