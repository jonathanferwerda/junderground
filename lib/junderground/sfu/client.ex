defmodule Junderground.Sfu.Client do
  @moduledoc """
  The two LiveKit room-service calls the switch needs: `RemoveParticipant` and
  `ListParticipants`.

  Both are Twirp POSTs under `<http-base>/twirp/livekit.RoomService/`, with a
  short admin JWT and a JSON body. The base is `Sfu.http_base/0`, so a URL such
  as `wss://thejunderground.com/sfu` becomes
  `https://thejunderground.com/sfu/twirp/...`; no host is hardcoded.

  Every failure is best effort: a revocation succeeds at the switch even if the
  media server cannot be reached. Tests inject the transport with
  `transport: fn url, headers, body -> {:ok, 200, "{}"} end` or the application
  environment key `:sfu_transport`.
  """

  alias Junderground.Sfu
  alias Junderground.Sfu.Token

  @doc "Remove one participant (a grant `jti`) from an opaque room."
  def remove_participant(room, identity, opts \\ [])
      when is_binary(room) and is_binary(identity) do
    with {:ok, url} <- endpoint("RemoveParticipant"),
         {:ok, jwt} <- Token.admin(room) do
      body = JSON.encode!(%{"room" => room, "identity" => identity})

      case transport(opts).(url, headers(jwt), body) do
        {:ok, status, _body} when status in 200..299 -> :ok
        {:ok, status, _body} -> {:error, {:status, status}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "The identities connected to an opaque room. Returns `{:ok, [jti]}`."
  def list_participants(room, opts \\ []) when is_binary(room) do
    with {:ok, url} <- endpoint("ListParticipants"),
         {:ok, jwt} <- Token.admin(room) do
      body = JSON.encode!(%{"room" => room})

      case transport(opts).(url, headers(jwt), body) do
        {:ok, status, response} when status in 200..299 ->
          case JSON.decode(response) do
            {:ok, %{"participants" => participants}} when is_list(participants) ->
              {:ok,
               participants
               |> Enum.map(& &1["identity"])
               |> Enum.filter(&is_binary/1)}

            {:ok, _other} ->
              {:ok, []}

            _ ->
              {:error, :bad_response}
          end

        {:ok, status, _body} ->
          {:error, {:status, status}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp endpoint(action) do
    case Sfu.http_base() do
      nil -> {:error, :unconfigured}
      base -> {:ok, base <> "/twirp/livekit.RoomService/" <> action}
    end
  end

  defp headers(jwt) do
    [
      {"authorization", "Bearer " <> jwt},
      {"content-type", "application/json"}
    ]
  end

  defp transport(opts) do
    Keyword.get(opts, :transport) ||
      Application.get_env(:junderground, :sfu_transport) ||
      (&post_json/3)
  end

  defp post_json(url, headers, body) do
    http_headers =
      Enum.map(headers, fn {name, value} ->
        {String.to_charlist(name), String.to_charlist(value)}
      end)

    request = {String.to_charlist(url), http_headers, ~c"application/json", body}

    case :httpc.request(
           :post,
           request,
           [timeout: 2_000, connect_timeout: 1_000],
           body_format: :binary
         ) do
      {:ok, {{_, status, _}, _, response}} -> {:ok, status, response}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end
