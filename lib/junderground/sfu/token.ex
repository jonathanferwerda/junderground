defmodule Junderground.Sfu.Token do
  @moduledoc """
  A LiveKit join token: HS256 JWT, no JOSE and no new dependency.

  The participant identity is the grant's `jti`, never the handle. The video
  grant maps the room role onto LiveKit's capabilities:

  | grant role | publish | admin |
  | --- | --- | --- |
  | citizen | audio + video | yes |
  | resident | audio + video | no |
  | guest | audio, plus camera only when the grant was clamped with `publish_video` | no |

  `canPublish` and `canSubscribe` also require the matching grant capability, so
  a `join`-only grant cannot publish even if its role normally could. Signaling
  stays on the switch: `canPublishData` and `roomRecord` are always false.
  """

  alias Junderground.Sfu

  @header %{"alg" => "HS256", "typ" => "JWT"}
  @admin_ttl 60

  @doc """
  Mint a join JWT for a verified grant payload.

  Returns `{:ok, %{token: jwt, room: opaque, expires: unix}}`. The lifetime is
  `min(grant.exp, now + sfu_token_ttl)`.
  """
  def mint(grant, opts \\ []) when is_map(grant) do
    with {:ok, jti} <- string_field(grant, "jti"),
         {:ok, room_key} <- string_field(grant, "room_key"),
         {:ok, role} <- string_field(grant, "role"),
         {:ok, grant_exp} <- int_field(grant, "exp") do
      now = Keyword.get(opts, :now, System.system_time(:second))
      secret = Keyword.get(opts, :secret) || Sfu.secret()

      cond do
        grant_exp <= now ->
          {:error, :expired}

        not is_binary(secret) or secret == "" ->
          {:error, :unconfigured}

        true ->
          ttl = Keyword.get(opts, :ttl, Sfu.token_ttl())
          exp = min(grant_exp, now + ttl)
          caps = List.wrap(grant["caps"])
          room = Sfu.opaque_room(room_key)

          video = %{
            "room" => room,
            "roomJoin" => true,
            "roomCreate" => false,
            "roomRecord" => false,
            "canPublish" => can_publish?(role, caps),
            "canSubscribe" => "subscribe" in caps,
            "canPublishData" => false,
            "roomAdmin" => role == "citizen"
          }

          video = maybe_sources(video, role, caps)

          claims = %{
            "iss" => Sfu.key(),
            "sub" => jti,
            "nbf" => now,
            "exp" => exp,
            "video" => video
          }

          {:ok, %{token: sign(claims, secret), room: room, expires: exp}}
      end
    end
  end

  @doc "A short admin JWT for the Twirp room service. Returns `{:ok, jwt}`."
  def admin(room, opts \\ []) when is_binary(room) do
    now = Keyword.get(opts, :now, System.system_time(:second))
    ttl = Keyword.get(opts, :ttl, @admin_ttl)
    secret = Keyword.get(opts, :secret) || Sfu.secret()

    if is_binary(secret) and secret != "" do
      claims = %{
        "iss" => Sfu.key(),
        "sub" => "junderground",
        "nbf" => now,
        "exp" => now + ttl,
        "video" => %{
          "room" => room,
          "roomJoin" => true,
          "roomCreate" => false,
          "roomRecord" => false,
          "canPublish" => false,
          "canSubscribe" => false,
          "canPublishData" => false,
          "roomAdmin" => true
        }
      }

      {:ok, sign(claims, secret)}
    else
      {:error, :unconfigured}
    end
  end

  defp can_publish?(role, caps) when role in ["citizen", "resident"] do
    Enum.any?(caps, &(&1 in ["publish_audio", "publish_video"]))
  end

  defp can_publish?("guest", caps) do
    Enum.any?(caps, &(&1 in ["publish_audio", "publish_video"]))
  end

  defp can_publish?(_role, _caps), do: false

  # LiveKit lets a token name the sources it may publish. A guest is audio-only
  # unless the grant carries publish_video; a role that can only publish audio
  # is restricted to the microphone as well.
  defp maybe_sources(video, role, caps) do
    cond do
      not video["canPublish"] ->
        video

      role == "guest" ->
        sources = ["microphone"] ++ if("publish_video" in caps, do: ["camera"], else: [])
        Map.put(video, "canPublishSources", sources)

      "publish_video" in caps ->
        video

      "publish_audio" in caps ->
        Map.put(video, "canPublishSources", ["microphone"])

      true ->
        video
    end
  end

  defp sign(claims, secret) do
    header = b64(JSON.encode!(@header))
    payload = b64(JSON.encode!(claims))
    signature = :crypto.mac(:hmac, :sha256, secret, header <> "." <> payload) |> b64()
    header <> "." <> payload <> "." <> signature
  end

  defp b64(bin), do: Base.url_encode64(bin, padding: false)

  defp string_field(map, key) do
    case map[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :bad_grant}
    end
  end

  defp int_field(map, key) do
    case map[key] do
      value when is_integer(value) -> {:ok, value}
      _ -> {:error, :bad_grant}
    end
  end
end
