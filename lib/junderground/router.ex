defmodule Junderground.Router do
  @moduledoc """
  The headless HTTP surface. Every write is a signed record; every read is
  either public or owner-only. See `docs/API.md` for the contract.
  """

  use Plug.Router

  alias Junderground.{Auth, Directory, Rooms}

  plug(Plug.RequestId)
  plug(Plug.Logger, log: :debug)
  plug(:match)
  plug(:dispatch)

  @max_body 1_000_000
  @default_limit 100
  @max_limit 500

  # ---- meta ----------------------------------------------------------------

  get "/v1/meta" do
    json(conn, 200, %{
      "name" => "junderground",
      "version" => Junderground.version(),
      "pubkey" => Junderground.ServerKey.public_b64(),
      "public_url" => Application.get_env(:junderground, :public_url, "http://localhost:4100"),
      "issued" => System.system_time(:second),
      "houses" => Directory.count(),
      "max_skew" => Auth.max_skew(),
      "features" => ["signed-records", "room-grants", "turn-credentials"],
      "turn" => %{
        "urls" => Application.get_env(:junderground, :turn_urls, []),
        "ttl" => 600
      }
    })
  end

  # ---- house records -------------------------------------------------------

  post "/v1/houses" do
    case read_json(conn) do
      {:ok, conn, _raw, record} ->
        case Directory.register(record) do
          {:ok, :unchanged} ->
            json(conn, 200, %{"ok" => true, "unchanged" => true, "handle" => record["handle"]})

          {:ok, info} ->
            json(conn, 201, %{"ok" => true, "handle" => info.handle, "seq" => info.seq})

          {:error, reason} ->
            fail(conn, reason)
        end

      {:error, conn, reason} ->
        fail(conn, reason)
    end
  end

  post "/v1/houses/:handle/records" do
    case read_json(conn) do
      {:ok, conn, raw, record} ->
        with {:ok, requester} <- Auth.verify(conn, raw),
             :ok <- same_handle(requester, handle),
             :ok <- record_handle(record, handle),
             {:ok, _} <- Directory.append(record) do
          json(conn, 200, %{"ok" => true, "handle" => handle, "seq" => record["seq"]})
        else
          {:error, reason} -> fail(conn, reason)
        end

      {:error, conn, reason} ->
        fail(conn, reason)
    end
  end

  get "/v1/houses/:handle" do
    case Directory.latest(handle) do
      {:ok, %{"tombstoned" => true}} ->
        json(conn, 410, %{
          "error" => %{"code" => "retired", "message" => "this handle is retired"}
        })

      {:ok, head} ->
        show(conn, handle, head)

      {:error, _} ->
        fail(conn, :not_found)
    end
  end

  get "/v1/houses/:handle/records" do
    conn = Plug.Conn.fetch_query_params(conn)
    since = int_param(conn.query_params["since"], 0)

    case Directory.latest(handle) do
      {:ok, %{"tombstoned" => true}} ->
        fail(conn, :retired)

      {:ok, head} ->
        if visible_to?(conn, handle, head) do
          {:ok, records} = Directory.history(handle, since)
          json(conn, 200, %{"handle" => handle, "records" => records})
        else
          fail(conn, :not_found)
        end

      {:error, _} ->
        fail(conn, :not_found)
    end
  end

  # ---- directory feed and mirroring ---------------------------------------

  get "/v1/directory" do
    conn = Plug.Conn.fetch_query_params(conn)
    since = int_param(conn.query_params["since"], 0)
    limit = conn.query_params["limit"] |> int_param(@default_limit) |> min(@max_limit) |> max(0)

    {:ok, records} = Directory.feed(since, limit)

    records =
      Enum.filter(records, fn record -> (record["visibility"] || "public") == "public" end)

    json(conn, 200, %{"records" => records})
  end

  post "/v1/mirror" do
    case read_json(conn) do
      {:ok, conn, _raw, %{"records" => records}} when is_list(records) ->
        {:ok, results} = Directory.mirror(records)

        json(conn, 200, %{
          "results" =>
            Enum.map(results, fn {h, r} -> %{"handle" => h, "result" => to_string(r)} end)
        })

      {:ok, conn, _raw, _body} ->
        fail(conn, :bad_request)

      {:error, conn, reason} ->
        fail(conn, reason)
    end
  end

  # ---- rooms ---------------------------------------------------------------

  post "/v1/rooms" do
    case read_json(conn) do
      {:ok, conn, raw, record} ->
        with {:ok, requester} <- Auth.verify(conn, raw),
             :ok <- same_handle(requester, record["handle"]) do
          case Rooms.register(record) do
            {:ok, :unchanged} ->
              json(conn, 200, %{"ok" => true, "unchanged" => true})

            {:ok, info} ->
              json(conn, 201, %{
                "ok" => true,
                "handle" => info.handle,
                "room" => info.room,
                "seq" => info.seq
              })

            {:error, reason} ->
              fail(conn, reason)
          end
        else
          {:error, reason} -> fail(conn, reason)
        end

      {:error, conn, reason} ->
        fail(conn, reason)
    end
  end

  get "/v1/rooms/:handle" do
    case Rooms.list(handle) do
      {:ok, heads} ->
        rooms = Enum.map(heads, &room_meta/1)
        json(conn, 200, %{"handle" => handle, "rooms" => rooms})
    end
  end

  get "/v1/rooms/:handle/:room" do
    case Rooms.latest(handle, room) do
      {:ok, head} -> json(conn, 200, room_meta(head))
      {:error, _} -> fail(conn, :not_found)
    end
  end

  post "/v1/rooms/:handle/:room/token" do
    case read_json(conn) do
      {:ok, conn, raw, body} ->
        with {:ok, requester} <- Auth.verify(conn, raw),
             {:ok, grant} <- Rooms.grant(handle, room, requester, body) do
          json(conn, 200, grant)
        else
          {:error, reason} -> fail(conn, reason)
        end

      {:error, conn, reason} ->
        fail(conn, reason)
    end
  end

  post "/v1/rooms/:handle/:room/revoke" do
    case read_json(conn) do
      {:ok, conn, raw, body} ->
        with {:ok, requester} <- Auth.verify(conn, raw),
             :ok <- Rooms.revoke(handle, room, requester, body["jti"], body["expires"]) do
          json(conn, 200, %{"ok" => true, "jti" => body["jti"]})
        else
          {:error, reason} -> fail(conn, reason)
        end

      {:error, conn, reason} ->
        fail(conn, reason)
    end
  end

  match _ do
    fail(conn, :not_found)
  end

  # ---- helpers -------------------------------------------------------------

  defp show(conn, handle, head) do
    if visible_to?(conn, handle, head) do
      json(conn, 200, head["record"])
    else
      fail(conn, :not_found)
    end
  end

  defp visible_to?(conn, handle, head) do
    case head["record"]["visibility"] || "public" do
      "public" ->
        true

      _private ->
        match?({:ok, %{handle: ^handle}}, Auth.verify(conn, ""))
    end
  end

  defp room_meta(head) do
    record = head["record"]

    %{
      "handle" => record["handle"],
      "room" => record["room"],
      "name" => record["name"],
      "policy" => record["policy"],
      "max" => record["max"],
      "recording" => record["recording"],
      "expires" => record["expires"],
      "room_key" => head["room_key"]
    }
  end

  defp same_handle(%{handle: handle}, handle), do: :ok
  defp same_handle(_requester, _handle), do: {:error, :forbidden}

  defp record_handle(record, handle) do
    if is_map(record) and record["handle"] == handle, do: :ok, else: {:error, :bad_handle}
  end

  defp int_param(value, _default) when is_integer(value), do: value

  defp int_param(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> default
    end
  end

  defp int_param(_value, default), do: default

  defp read_json(conn) do
    case Plug.Conn.read_body(conn, length: @max_body) do
      {:ok, body, conn} ->
        case JSON.decode(body) do
          {:ok, map} when is_map(map) -> {:ok, conn, body, map}
          _ -> {:error, conn, :bad_json}
        end

      {:more, _partial, conn} ->
        {:error, conn, :too_large}

      {:error, _reason} ->
        {:error, conn, :read_failed}
    end
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, JSON.encode!(body))
  end

  defp fail(conn, reason) when is_atom(reason) do
    json(conn, status_for(reason), %{"error" => %{"code" => to_string(reason)}})
  end

  defp status_for(:not_found), do: 404
  defp status_for(:unknown_house), do: 404
  defp status_for(:missing_auth), do: 401
  defp status_for(:stale_timestamp), do: 401
  defp status_for(:bad_timestamp), do: 401
  defp status_for(:forbidden), do: 403
  defp status_for(:invite_required), do: 403
  defp status_for(:retired), do: 410
  defp status_for(:expired), do: 410

  defp status_for(reason)
       when reason in [
              :replay,
              :taken,
              :stale,
              :gap,
              :broken_chain,
              :wrong_key,
              :not_registered,
              :bad_first_seq
            ],
       do: 409

  defp status_for(:revoked), do: 409
  defp status_for(_), do: 422
end
