defmodule Junderground.Router do
  @moduledoc """
  The headless HTTP surface. Every write is a signed record; reads are public,
  owner-only, or administrator-only. See `docs/API.md` for the contract.
  """

  use Plug.Router

  alias Junderground.{Admin, Admission, Auth, Constructs, Directory, Peers, Presence, Rooms}

  plug(Plug.RequestId)
  plug(Plug.Logger, log: :debug)
  plug(:match)
  plug(:dispatch)

  @max_body 1_000_000
  @default_limit 100
  @max_limit 500

  # ---- meta and the dial ------------------------------------------------

  get "/v1/meta" do
    json(conn, 200, %{
      "name" => "junderground",
      "version" => Junderground.version(),
      "pubkey" => Junderground.ServerKey.public_b64(),
      "public_url" => Application.get_env(:junderground, :public_url, "http://localhost:4100"),
      "issued" => System.system_time(:second),
      "houses" => Directory.count(),
      "max_skew" => Auth.max_skew(),
      "features" => [
        "signed-records",
        "room-grants",
        "turn-credentials",
        "admission",
        "crest",
        "constructs",
        "peers",
        "presence",
        "tickets"
      ],
      "peers" => peer_count(),
      "admission" => %{
        "requires_approval" => not Application.get_env(:junderground, :auto_approve, false),
        "statuses" => Admission.statuses(),
        "admins" => Admin.count()
      },
      "constructs" => Constructs.defaults(),
      "turn" => %{
        "urls" => Application.get_env(:junderground, :turn_urls, []),
        "ttl" => 600
      }
    })
  end

  get "/v1/constructs" do
    json(conn, 200, %{"kinds" => Constructs.kinds(), "defaults" => Constructs.defaults()})
  end

  get "/v1/dial" do
    conn = Plug.Conn.fetch_query_params(conn)
    params = conn.query_params
    {:ok, constructs} = Constructs.normalize(Map.take(params, Constructs.names()))
    channel = params["channel"] || Constructs.channel_id(constructs)
    {:ok, heads} = Rooms.by_channel(channel)

    rooms =
      heads
      |> Enum.filter(& &1["advertised"])
      |> Enum.filter(&Admission.admitted?(&1["record"]["handle"]))
      |> Enum.map(&room_meta/1)

    json(conn, 200, %{"channel" => channel, "constructs" => constructs, "rooms" => rooms})
  end

  # ---- other jundergrounds ---------------------------------------------

  post "/v1/peers" do
    case read_json(conn) do
      {:ok, conn, _raw, record} ->
        case Peers.register(record) do
          {:ok, info} ->
            json(conn, 201, %{"ok" => true, "id" => info.id, "status" => info.status})

          {:error, reason} ->
            fail(conn, reason)
        end

      {:error, conn, reason} ->
        fail(conn, reason)
    end
  end

  get "/v1/peers" do
    {:ok, peers} = Peers.list()
    json(conn, 200, %{"peers" => peers})
  end

  get "/v1/peers/:id" do
    case Peers.get(id) do
      {:ok, peer} ->
        if peer["status"] in ["approved", "probation"] do
          json(conn, 200, %{
            "id" => peer["id"],
            "name" => peer["record"]["name"],
            "url" => peer["record"]["url"],
            "pubkey" => peer["record"]["pubkey"],
            "status" => peer["status"]
          })
        else
          fail(conn, :not_found)
        end

      _ ->
        fail(conn, :not_found)
    end
  end

  # ---- house records ---------------------------------------------------

  post "/v1/houses" do
    case read_json(conn) do
      {:ok, conn, _raw, record} ->
        case Directory.register(record) do
          {:ok, :unchanged} ->
            json(conn, 200, %{"ok" => true, "unchanged" => true, "handle" => record["handle"]})

          {:ok, info} ->
            admission = admission_view(record["handle"], true)

            json(conn, 201, %{
              "ok" => true,
              "handle" => info.handle,
              "seq" => info.seq,
              "admission" => admission
            })

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
    viewer = viewer(conn)

    case Directory.latest(handle) do
      {:ok, %{"tombstoned" => true}} ->
        json(conn, 410, %{
          "error" => %{"code" => "retired", "message" => "this handle is retired"}
        })

      {:ok, head} ->
        if visible_record?(handle, head, viewer) do
          owner? = match?(%{handle: ^handle}, viewer)

          json(conn, 200, %{
            "record" => head["record"],
            "fingerprint" => head["fingerprint"],
            "admission" => admission_view(handle, owner?)
          })
        else
          fail(conn, :not_found)
        end

      {:error, _} ->
        fail(conn, :not_found)
    end
  end

  get "/v1/houses/:handle/records" do
    conn = Plug.Conn.fetch_query_params(conn)
    viewer = viewer(conn)
    since = int_param(conn.query_params["since"], 0)

    case Directory.latest(handle) do
      {:ok, %{"tombstoned" => true}} ->
        fail(conn, :retired)

      {:ok, head} ->
        if visible_record?(handle, head, viewer) do
          {:ok, records} = Directory.history(handle, since)
          owner? = match?(%{handle: ^handle}, viewer)

          json(conn, 200, %{
            "handle" => handle,
            "records" => records,
            "admission" => admission_view(handle, owner?)
          })
        else
          fail(conn, :not_found)
        end

      {:error, _} ->
        fail(conn, :not_found)
    end
  end

  # ---- directory feed and mirroring -------------------------------------

  get "/v1/directory" do
    conn = Plug.Conn.fetch_query_params(conn)
    since = int_param(conn.query_params["since"], 0)
    limit = conn.query_params["limit"] |> int_param(@default_limit) |> min(@max_limit) |> max(0)

    {:ok, records} = Directory.feed(since, limit)

    records =
      Enum.filter(records, fn record ->
        (record["visibility"] || "public") == "public" and Admission.admitted?(record["handle"])
      end)

    json(conn, 200, %{"records" => records})
  end

  post "/v1/mirror" do
    case read_json(conn) do
      {:ok, conn, raw, %{"records" => records}} when is_list(records) ->
        with {:ok, _peer} <- Peers.verify(conn, raw) do
          {:ok, results} = Directory.mirror(records)

          json(conn, 200, %{
            "results" =>
              Enum.map(results, fn {handle, result} ->
                %{"handle" => handle, "result" => to_string(result)}
              end)
          })
        else
          {:error, reason} -> fail(conn, reason)
        end

      {:ok, conn, _raw, _body} ->
        fail(conn, :bad_request)

      {:error, conn, reason} ->
        fail(conn, reason)
    end
  end

  # ---- reports ----------------------------------------------------------

  post "/v1/reports" do
    case read_json(conn) do
      {:ok, conn, raw, body} ->
        with {:ok, requester} <- Auth.verify(conn, raw),
             :ok <- admitted_writer(requester.handle),
             {:ok, record} <-
               Admission.report(body["handle"], requester.handle, body["reason"], body["detail"]) do
          json(conn, 202, %{"ok" => true, "id" => record["id"]})
        else
          {:error, reason} -> fail(conn, reason)
        end

      {:error, conn, reason} ->
        fail(conn, reason)
    end
  end

  # ---- rooms ------------------------------------------------------------

  post "/v1/rooms" do
    case read_json(conn) do
      {:ok, conn, raw, record} ->
        with {:ok, requester} <- Auth.verify(conn, raw),
             :ok <- same_handle(requester, record["handle"]),
             :ok <- room_permission(requester.handle, record["room"]) do
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
        json(conn, 200, %{"handle" => handle, "rooms" => Enum.map(heads, &room_meta/1)})
    end
  end

  get "/v1/rooms/:handle/:room" do
    viewer = viewer(conn)

    case Rooms.latest(handle, room) do
      {:ok, head} ->
        if Admission.admitted?(handle) or match?(%{handle: ^handle}, viewer) do
          json(conn, 200, room_meta(head))
        else
          fail(conn, :room_closed)
        end

      {:error, _} ->
        fail(conn, :not_found)
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

  post "/v1/rooms/:handle/:room/tickets" do
    case read_json(conn) do
      {:ok, conn, raw, body} ->
        with {:ok, requester} <- Auth.verify(conn, raw),
             {:ok, ticket} <- Rooms.issue_ticket(handle, room, requester, body) do
          json(conn, 201, ticket)
        else
          {:error, reason} -> fail(conn, reason)
        end

      {:error, conn, reason} ->
        fail(conn, reason)
    end
  end

  get "/v1/rooms/:handle/:room/tickets" do
    with {:ok, requester} <- Auth.verify(conn, ""),
         :ok <- same_handle(requester, handle),
         {:ok, tickets} <- Rooms.list_tickets(handle, room) do
      json(conn, 200, %{"tickets" => tickets})
    else
      {:error, reason} -> fail(conn, reason)
    end
  end

  post "/v1/rooms/:handle/:room/presence" do
    case read_json(conn) do
      {:ok, conn, raw, body} ->
        with {:ok, requester} <- Auth.verify(conn, raw),
             {:ok, payload} <- Rooms.verify_grant(body["grant"]),
             :ok <- grant_room(payload, handle, room),
             :ok <- grant_subject(payload, requester),
             {:ok, entry, roster} <-
               Presence.join(
                 handle <> "/" <> room,
                 requester.handle,
                 payload["caps"] || [],
                 payload["jti"],
                 body["ttl"]
               ) do
          json(conn, 200, %{
            "presence_id" => entry["id"],
            "expires" => entry["expires"],
            "room" => handle <> "/" <> room,
            "roster" => roster,
            "count" => length(roster)
          })
        else
          {:error, reason} -> fail(conn, reason)
        end

      {:error, conn, reason} ->
        fail(conn, reason)
    end
  end

  post "/v1/rooms/:handle/:room/presence/leave" do
    case read_json(conn) do
      {:ok, conn, raw, body} ->
        with {:ok, requester} <- Auth.verify(conn, raw),
             :ok <- Presence.leave(handle <> "/" <> room, body["presence_id"], requester.handle) do
          json(conn, 200, %{"ok" => true})
        else
          {:error, reason} -> fail(conn, reason)
        end

      {:error, conn, reason} ->
        fail(conn, reason)
    end
  end

  get "/v1/rooms/:handle/:room/presence" do
    case Rooms.latest(handle, room) do
      {:ok, head} ->
        viewer = viewer(conn)

        open? =
          head["record"]["policy"] == "open" or head["advertised"] or
            match?(%{handle: ^handle}, viewer)

        if open? do
          {:ok, roster} = Presence.roster(handle <> "/" <> room)

          json(conn, 200, %{
            "room" => handle <> "/" <> room,
            "roster" => roster,
            "count" => length(roster)
          })
        else
          fail(conn, :forbidden)
        end

      {:error, _} ->
        fail(conn, :not_found)
    end
  end

  # ---- administrator (a person or an approval agent) --------------------

  get "/v1/admin/queue" do
    with {:ok, _admin} <- Admin.verify(conn, "") do
      json(conn, 200, Admission.queue())
    else
      {:error, reason} -> fail(conn, reason)
    end
  end

  get "/v1/admin/houses/:handle" do
    with {:ok, _admin} <- Admin.verify(conn, ""),
         {:ok, head} <- Directory.latest(handle) do
      {:ok, records} = Directory.history(handle)
      {:ok, admission} = Admission.status(handle)

      json(conn, 200, %{
        "record" => head["record"],
        "fingerprint" => head["fingerprint"],
        "admission" => admission,
        "records" => records
      })
    else
      {:error, reason} -> fail(conn, reason)
    end
  end

  post "/v1/admin/houses/:handle/status" do
    case read_json(conn) do
      {:ok, conn, raw, body} ->
        with {:ok, admin} <- Admin.verify(conn, raw),
             {:ok, record} <-
               Admission.decide(
                 handle,
                 body["status"],
                 "admin:" <> String.slice(admin.admin, 0, 12),
                 body["reason"],
                 body["review_at"]
               ) do
          json(conn, 200, %{"ok" => true, "admission" => record})
        else
          {:error, reason} -> fail(conn, reason)
        end

      {:error, conn, reason} ->
        fail(conn, reason)
    end
  end

  get "/v1/admin/audit" do
    conn = Plug.Conn.fetch_query_params(conn)
    since = int_param(conn.query_params["since"], 0)

    with {:ok, _admin} <- Admin.verify(conn, ""),
         {:ok, records} <- Admission.audit(since) do
      json(conn, 200, %{"decisions" => records})
    else
      {:error, reason} -> fail(conn, reason)
    end
  end

  get "/v1/admin/reports" do
    conn = Plug.Conn.fetch_query_params(conn)
    since = int_param(conn.query_params["since"], 0)

    with {:ok, _admin} <- Admin.verify(conn, ""),
         {:ok, records} <- Admission.reports(since) do
      json(conn, 200, %{"reports" => records})
    else
      {:error, reason} -> fail(conn, reason)
    end
  end

  post "/v1/admin/houses/:handle/review" do
    case read_json(conn) do
      {:ok, conn, raw, body} ->
        with {:ok, admin} <- Admin.verify(conn, raw),
             {:ok, result} <-
               Admission.review(
                 handle,
                 body["verdict"],
                 "admin:" <> String.slice(admin.admin, 0, 12),
                 body["detail"] || "",
                 body["evidence"] || ""
               ) do
          json(conn, 200, result)
        else
          {:error, reason} -> fail(conn, reason)
        end

      {:error, conn, reason} ->
        fail(conn, reason)
    end
  end

  get "/v1/admin/reviews" do
    conn = Plug.Conn.fetch_query_params(conn)
    since = int_param(conn.query_params["since"], 0)

    with {:ok, _admin} <- Admin.verify(conn, ""),
         {:ok, records} <- Admission.reviews(since) do
      json(conn, 200, %{"reviews" => records})
    else
      {:error, reason} -> fail(conn, reason)
    end
  end

  get "/v1/admin/peers" do
    with {:ok, _admin} <- Admin.verify(conn, "") do
      {:ok, peers} = Peers.list()
      json(conn, 200, %{"peers" => peers, "queue" => Peers.queue()})
    else
      {:error, reason} -> fail(conn, reason)
    end
  end

  get "/v1/admin/peers/queue" do
    with {:ok, _admin} <- Admin.verify(conn, "") do
      json(conn, 200, Peers.queue())
    else
      {:error, reason} -> fail(conn, reason)
    end
  end

  get "/v1/admin/peers/audit" do
    conn = Plug.Conn.fetch_query_params(conn)
    since = int_param(conn.query_params["since"], 0)

    with {:ok, _admin} <- Admin.verify(conn, ""),
         {:ok, records} <- Peers.audit(since) do
      json(conn, 200, %{"decisions" => records})
    else
      {:error, reason} -> fail(conn, reason)
    end
  end

  post "/v1/admin/peers/:id/status" do
    case read_json(conn) do
      {:ok, conn, raw, body} ->
        with {:ok, admin} <- Admin.verify(conn, raw),
             {:ok, peer} <-
               Peers.decide(
                 id,
                 body["status"],
                 "admin:" <> String.slice(admin.admin, 0, 12),
                 body["reason"],
                 body["review_at"]
               ) do
          json(conn, 200, %{"ok" => true, "id" => peer["id"], "status" => peer["status"]})
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

  # ---- helpers ----------------------------------------------------------

  defp viewer(conn) do
    case Auth.verify(conn, "") do
      {:ok, requester} -> requester
      _ -> nil
    end
  end

  defp visible_record?(handle, head, viewer) do
    cond do
      not Admission.admitted?(handle) ->
        match?(%{handle: ^handle}, viewer)

      (head["record"]["visibility"] || "public") == "public" ->
        true

      true ->
        match?(%{handle: ^handle}, viewer)
    end
  end

  defp admission_view(handle, owner?) do
    case Admission.status(handle) do
      {:ok, record} ->
        base = %{
          "status" => record["status"],
          "since" => record["since"],
          "review_at" => record["review_at"]
        }

        if owner?, do: Map.put(base, "reason", record["reason"]), else: base

      _ ->
        %{"status" => "unregistered"}
    end
  end

  defp room_meta(head) do
    record = head["record"]

    %{
      "handle" => record["handle"],
      "room" => record["room"],
      "name" => record["name"],
      "constructs" => head["constructs"],
      "channel" => head["channel"],
      "advertised" => head["advertised"],
      "policy" => record["policy"],
      "max" => record["max"],
      "recording" => record["recording"],
      "expires" => record["expires"],
      "room_key" => head["room_key"]
    }
  end

  defp room_permission(handle, room) do
    case Rooms.latest(handle, room) do
      {:ok, _head} ->
        if Admission.may_write?(handle), do: :ok, else: {:error, :not_admitted}

      _ ->
        if Admission.may_create_room?(handle), do: :ok, else: {:error, :not_admitted}
    end
  end

  defp admitted_writer(handle) do
    if Admission.may_write?(handle), do: :ok, else: {:error, :not_admitted}
  end

  defp peer_count do
    if Process.whereis(Peers) do
      case Peers.list() do
        {:ok, peers} -> length(peers)
        _ -> 0
      end
    else
      0
    end
  end

  defp grant_room(%{"room" => value}, handle, room) do
    if value == handle <> "/" <> room, do: :ok, else: {:error, :wrong_room}
  end

  defp grant_room(_payload, _handle, _room), do: {:error, :bad_grant}

  defp grant_subject(%{"sub" => sub}, %{handle: handle}) do
    if sub == handle, do: :ok, else: {:error, :forbidden}
  end

  defp grant_subject(_payload, _requester), do: {:error, :bad_grant}

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
  defp status_for(:not_admin), do: 403
  defp status_for(:not_admitted), do: 403
  defp status_for(:invite_required), do: 403
  defp status_for(:retired), do: 410
  defp status_for(:expired), do: 410
  defp status_for(:room_closed), do: 410
  defp status_for(:ticket_required), do: 403
  defp status_for(:ticket_spent), do: 409
  defp status_for(:ticket_not_found), do: 404
  defp status_for(:wrong_room), do: 403
  defp status_for(:bad_grant), do: 422

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
