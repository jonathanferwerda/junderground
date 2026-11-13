defmodule Junderground.Sfu do
  @moduledoc """
  The switch's decision about *how* a room carries media.

  The switch is the control plane; media never enters this process. Below
  `sfu_threshold` live sockets a room uses the full mesh the reference client
  already builds; at or above it the room is handed a LiveKit join token
  instead. A room whose policy `max` is below the threshold is never SFU.

  The opaque SFU room name is the only identifier the media server sees. It is
  derived from the room record's `room_key`, so every house in the room gets
  the same name and the name cannot be turned back into a handle:

      "r_" <> base64url(HMAC-SHA256(sfu_secret, "room\\0" <> room_key))[0..15]

  `available?/0` is configuration plus the health cache; a token request reads
  the cached answer and never waits for a probe.
  """

  alias Junderground.Sfu.Health

  @adapter "livekit"
  @default_threshold 5
  @default_ttl 300

  @doc "True when a URL, key and secret are configured. Health is not consulted."
  def enabled? do
    present?(url()) and present?(key()) and present?(secret())
  end

  @doc "Configured and the health cache says the media server is up."
  def available?, do: enabled?() and Health.up?()

  @doc """
  `"mesh"` or `"sfu"` for a room record and its live socket count.

  `mode/2` also accepts a bare room key (a string) when the caller has no room
  record; that path applies the threshold only, so callers that know `max`
  should pass the record.
  """
  def mode(%{} = room, count) when is_integer(count) do
    mode(Map.get(room, "max") || 16, count)
  end

  def mode(max, count) when is_integer(max) and is_integer(count) do
    if max >= threshold() and count >= threshold(), do: "sfu", else: "mesh"
  end

  def mode(room_key, count) when is_binary(room_key) and is_integer(count) do
    if count >= threshold(), do: "sfu", else: "mesh"
  end

  def mode(_room, _count), do: "mesh"

  @doc """
  The `media` object a grant and a `hello` carry, with a human-readable reason.

  The mode is the one that would actually work now: a threshold-sized room made
  `mesh` because the SFU is missing or unhealthy says so in `reason`.
  """
  def media(%{} = room, count) when is_integer(count) do
    max = Map.get(room, "max") || 16

    cond do
      not is_integer(max) or max < threshold() ->
        %{"mode" => "mesh", "reason" => "room_max"}

      count < threshold() ->
        %{"mode" => "mesh", "reason" => "below_threshold"}

      not enabled?() ->
        %{"mode" => "mesh", "reason" => "sfu_unconfigured"}

      not available?() ->
        %{"mode" => "mesh", "reason" => "sfu_unavailable"}

      true ->
        %{"mode" => "sfu", "reason" => "threshold"}
    end
  end

  def media(handle, room) when is_binary(handle) and is_binary(room) do
    case Junderground.Rooms.latest(handle, room) do
      {:ok, head} -> media(head["record"], peer_count(handle <> "/" <> room))
      _ -> %{"mode" => "mesh", "reason" => "not_found"}
    end
  rescue
    _ -> %{"mode" => "mesh", "reason" => "not_found"}
  end

  @doc "Live sockets in a room, or 0 when signaling is not running."
  def peer_count(room_key) do
    if Process.whereis(Junderground.Signaling.Registry) do
      Junderground.Signaling.count(room_key)
    else
      0
    end
  rescue
    _ -> 0
  end

  @doc "The opaque room name the SFU sees. Stable per room, not reversible."
  def opaque_room(room_key) when is_binary(room_key) do
    secret = secret()

    if present?(secret) do
      digest = :crypto.mac(:hmac, :sha256, secret, "room\0" <> room_key)
      "r_" <> (digest |> Base.url_encode64(padding: false) |> String.slice(0, 16))
    else
      raise ArgumentError, "sfu secret is not configured"
    end
  end

  @doc "The HTTP(S) base for the media server; `wss://` becomes `https://`."
  def http_base do
    case url() do
      value when is_binary(value) and value != "" ->
        value
        |> String.replace_prefix("wss://", "https://")
        |> String.replace_prefix("ws://", "http://")
        |> String.trim_trailing("/")

      _ ->
        nil
    end
  end

  @doc "The `sfu` block of `GET /v1/meta`."
  def meta, do: meta(available?())

  def meta(available?) do
    %{
      "available" => available?,
      "adapter" => @adapter,
      "url" => url(),
      "threshold" => threshold(),
      "token_ttl" => token_ttl()
    }
  end

  def url, do: env(:sfu_url)
  def key, do: env(:sfu_key)
  def secret, do: env(:sfu_secret)

  def threshold do
    case Application.get_env(:junderground, :sfu_threshold, @default_threshold) do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_threshold
    end
  end

  def token_ttl do
    case Application.get_env(:junderground, :sfu_token_ttl, @default_ttl) do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_ttl
    end
  end

  defp env(key) do
    case Application.get_env(:junderground, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp present?(value), do: is_binary(value) and value != ""
end
