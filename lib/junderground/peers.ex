defmodule Junderground.Peers do
  @moduledoc """
  Other jundergrounds.

  A peer is a switch, not a house, so it is not in the house directory. It
  registers with a self-signed record and goes through the same admission
  states: `pending`, `approved`, `probation`, `suspended`, `rejected`, `banned`.
  Only an `approved` peer may mirror records into this switch; `probation` is
  a read-only relationship (its own records can be fetched, but it may not
  push), and the stopped states may do nothing at all.

  A peer request is signed with the peer's own key and names it in
  `X-JG-Peer`; the signature covers the same message a house request does.
  """

  use GenServer

  alias Junderground.{Admin, Auth, Keys, Nonces}

  @table :junderground_peers
  @format "junderground-peer"
  @version 1
  @statuses ~w(pending approved probation suspended rejected banned)
  @admitting ~w(approved probation)
  @max_skew 3600

  # ---- api -----------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def statuses, do: @statuses

  def register(record), do: GenServer.call(__MODULE__, {:register, record})
  def list, do: GenServer.call(__MODULE__, :list)
  def get(id), do: GenServer.call(__MODULE__, {:get, id})
  def queue, do: GenServer.call(__MODULE__, :queue)
  def audit(since, limit \\ 100), do: GenServer.call(__MODULE__, {:audit, since, limit})

  def decide(id, status, by, reason, review_at) do
    GenServer.call(__MODULE__, {:decide, id, status, by, reason, review_at})
  end

  def admitted?(id) do
    case get(id) do
      {:ok, peer} -> peer["status"] in @admitting
      _ -> false
    end
  end

  def may_mirror?(id) do
    case get(id) do
      {:ok, peer} -> peer["status"] == "approved"
      _ -> false
    end
  end

  @doc "Verify a peer-signed request. Returns `{:ok, %{peer: peer, id: id}}`."
  def verify(conn, raw_body) do
    with {:ok, pub} <- header(conn, "x-jg-peer"),
         id = Keys.key_id(pub),
         true <- may_mirror?(id) or {:error, :not_admitted},
         {:ok, _peer} <- get(id),
         {:ok, ts_text} <- header(conn, "x-jg-timestamp"),
         {:ok, nonce} <- header(conn, "x-jg-nonce"),
         {:ok, sig64} <- header(conn, "x-jg-signature"),
         {:ok, ts} <- to_int(ts_text),
         :ok <- in_window(ts),
         :ok <- Nonces.check(nonce, 300),
         :ok <- check_signature(pub, conn, raw_body, ts_text, nonce, sig64) do
      {:ok, %{id: id}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :not_admitted}
    end
  end

  # ---- server --------------------------------------------------------------

  @impl true
  def init(opts) do
    dir = Keyword.get(opts, :data_dir, Application.get_env(:junderground, :data_dir, "data"))
    File.mkdir_p!(dir)
    path = Path.join(dir, "peers.dets")

    :dets.close(@table)

    {:ok, _} =
      :dets.open_file(@table, file: String.to_charlist(path), type: :set, auto_save: 2_000)

    {:ok, %{audit_seq: counter(:audit_seq)}}
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.close(@table)
    :ok
  end

  @impl true
  def handle_call({:register, record}, _from, state) do
    case validate(record) do
      :ok ->
        id = Keys.key_id(record["pubkey"])
        prior = lookup(id)

        cond do
          prior == nil ->
            now = System.system_time(:second)

            {status, reason, by} =
              if Admin.admin_key?(record["pubkey"]) do
                {"approved", "peer key is an administrator key", "system"}
              else
                {"pending", "awaiting review", ""}
              end

            peer = %{
              "id" => id,
              "record" => record,
              "status" => status,
              "first_seen" => now,
              "since" => now,
              "review_at" => 0,
              "reason" => reason,
              "by" => by,
              "revoked_before" => 0
            }

            :dets.insert(@table, {{:peer, id}, peer})
            {:reply, {:ok, %{id: id, status: status}}, state}

          record["sig"] == prior["record"]["sig"] ->
            {:reply, {:ok, %{id: id, status: prior["status"]}}, state}

          record["pubkey"] != prior["record"]["pubkey"] ->
            {:reply, {:error, :wrong_key}, state}

          record["seq"] != prior["record"]["seq"] + 1 ->
            {:reply, {:error, :gap}, state}

          record["prev"] != prior["record"]["sig"] ->
            {:reply, {:error, :broken_chain}, state}

          prior["status"] in ["suspended", "rejected", "banned"] ->
            {:reply, {:error, :not_admitted}, state}

          true ->
            peer = Map.put(prior, "record", record)
            :dets.insert(@table, {{:peer, id}, peer})
            {:reply, {:ok, %{id: id, status: peer["status"]}}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:list, _from, state) do
    peers =
      :dets.select(@table, [{{{:peer, :_}, :"$1"}, [], [:"$1"]}])
      |> Enum.filter(&(&1["status"] in @admitting and &1["record"]))
      |> Enum.map(&public_view/1)
      |> Enum.sort_by(& &1["name"])

    {:reply, {:ok, peers}, state}
  end

  def handle_call({:get, id}, _from, state) do
    case lookup(id) do
      nil -> {:reply, {:error, :not_found}, state}
      peer -> {:reply, {:ok, peer}, state}
    end
  end

  def handle_call(:queue, _from, state) do
    all = :dets.select(@table, [{{{:peer, :_}, :"$1"}, [], [:"$1"]}])

    pending =
      all
      |> Enum.filter(&(&1["status"] == "pending"))
      |> Enum.sort_by(& &1["first_seen"])
      |> Enum.map(&queue_view/1)

    probation =
      all
      |> Enum.filter(&(&1["status"] == "probation"))
      |> Enum.sort_by(& &1["review_at"])
      |> Enum.map(&queue_view/1)

    {:reply, %{"pending" => pending, "probation" => probation}, state}
  end

  def handle_call({:decide, id, status, by, reason, review_at}, _from, state) do
    cond do
      status not in @statuses ->
        {:reply, {:error, :bad_status}, state}

      lookup(id) == nil ->
        {:reply, {:error, :not_found}, state}

      true ->
        now = System.system_time(:second)
        prior = lookup(id)
        stopped = status in ["suspended", "rejected", "banned"]

        peer =
          prior
          |> Map.merge(%{
            "status" => status,
            "since" => now,
            "by" => by || "",
            "reason" => reason || "",
            "review_at" => if(is_integer(review_at), do: review_at, else: 0),
            "revoked_before" => if(stopped, do: now, else: prior["revoked_before"] || 0)
          })

        n = state.audit_seq + 1

        :dets.insert(@table, [
          {{:peer, id}, peer},
          {{:audit, n},
           %{
             "at" => now,
             "id" => id,
             "status" => status,
             "by" => by || "",
             "reason" => reason || "",
             "review_at" => peer["review_at"]
           }},
          {{:meta, :audit_seq}, n}
        ])

        {:reply, {:ok, peer}, %{state | audit_seq: n}}
    end
  end

  def handle_call({:audit, since, limit}, _from, state) do
    {:reply, {:ok, collect(since, max(limit, 0), state.audit_seq)}, state}
  end

  # ---- validation ----------------------------------------------------------

  defp validate(record) when is_map(record) do
    cond do
      record["format"] != @format -> {:error, :bad_format}
      record["version"] != @version -> {:error, :bad_version}
      not is_binary(record["name"]) or byte_size(record["name"]) > 200 -> {:error, :bad_name}
      not is_binary(record["url"]) or byte_size(record["url"]) > 500 -> {:error, :bad_url}
      not (record["url"] =~ ~r{^https?://}) -> {:error, :bad_url}
      not Keys.valid_public_key?(record["pubkey"]) -> {:error, :bad_pubkey}
      not is_integer(record["seq"]) or record["seq"] < 1 -> {:error, :bad_seq}
      not is_integer(record["issued"]) -> {:error, :bad_issued}
      record["issued"] > System.system_time(:second) + @max_skew -> {:error, :future}
      not is_binary(record["sig"]) -> {:error, :bad_signature}
      not Keys.verify_record(record) -> {:error, :bad_signature}
      record["seq"] > 1 and not is_binary(record["prev"]) -> {:error, :broken_chain}
      true -> :ok
    end
  end

  defp validate(_record), do: {:error, :bad_record}

  # ---- storage -------------------------------------------------------------

  defp lookup(id) do
    case :dets.lookup(@table, {:peer, id}) do
      [{{:peer, ^id}, peer}] -> peer
      _ -> nil
    end
  end

  defp queue_view(peer) do
    %{
      "id" => peer["id"],
      "name" => peer["record"]["name"],
      "url" => peer["record"]["url"],
      "pubkey" => peer["record"]["pubkey"],
      "status" => peer["status"],
      "first_seen" => peer["first_seen"],
      "review_at" => peer["review_at"],
      "reason" => peer["reason"],
      "record" => peer["record"]
    }
  end

  defp public_view(peer) do
    %{
      "id" => peer["id"],
      "name" => peer["record"]["name"],
      "url" => peer["record"]["url"],
      "pubkey" => peer["record"]["pubkey"],
      "status" => peer["status"],
      "since" => peer["since"]
    }
  end

  defp counter(name) do
    case :dets.lookup(@table, {:meta, name}) do
      [{{:meta, ^name}, n}] when is_integer(n) -> n
      _ -> 0
    end
  end

  defp collect(_since, limit, _top) when limit <= 0, do: []
  defp collect(since, _limit, top) when since >= top, do: []

  defp collect(since, limit, top) do
    last = min(since + limit, top)

    (since + 1)..last
    |> Enum.reduce([], fn n, acc ->
      case :dets.lookup(@table, {:audit, n}) do
        [{{:audit, ^n}, entry}] -> [entry | acc]
        _ -> acc
      end
    end)
    |> Enum.reverse()
  end

  # ---- signed request ------------------------------------------------------

  defp header(conn, name) do
    case Plug.Conn.get_req_header(conn, name) do
      [value | _] when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :missing_auth}
    end
  end

  defp to_int(text) do
    case Integer.parse(text) do
      {n, ""} -> {:ok, n}
      _ -> {:error, :bad_timestamp}
    end
  end

  defp in_window(ts) do
    if abs(System.system_time(:second) - ts) <= 300, do: :ok, else: {:error, :stale_timestamp}
  end

  defp check_signature(pub64, conn, body, timestamp, nonce, sig64) do
    with {:ok, pub} <- Base.decode64(pub64),
         {:ok, sig} <- Base.decode64(sig64) do
      msg = Auth.message(conn, body, timestamp, nonce)

      if :crypto.verify(:eddsa, :none, msg, sig, [pub, :ed25519]),
        do: :ok,
        else: {:error, :bad_signature}
    else
      _ -> {:error, :bad_signature}
    end
  end
end
