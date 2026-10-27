defmodule Junderground.Directory do
  @moduledoc """
  The append-only home of house records, persisted with DETS.

  Keys in the table:

    * `{:head, handle}`   — the current head (active key, sequence, signature)
    * `{:record, handle, seq}` — every accepted record, for history
    * `{:log, n}`         — a global order over accepted records, for mirrors
    * `{:meta, :log_seq}` — the last global number handed out

  The chain rules live in `Junderground.Record`; this module only decides
  whether a record may be appended and stores it.
  """

  use GenServer

  alias Junderground.Record

  @table :junderground_houses

  # ---- api -----------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def register(record), do: GenServer.call(__MODULE__, {:append, record})
  def append(record), do: GenServer.call(__MODULE__, {:append, record})
  def latest(handle), do: GenServer.call(__MODULE__, {:latest, handle})
  def live(handle), do: GenServer.call(__MODULE__, {:live, handle})
  def history(handle, since \\ 0), do: GenServer.call(__MODULE__, {:history, handle, since})
  def feed(since, limit \\ 100), do: GenServer.call(__MODULE__, {:feed, since, limit})
  def mirror(records), do: GenServer.call(__MODULE__, {:mirror, records}, 30_000)
  def count, do: GenServer.call(__MODULE__, :count)

  # ---- server --------------------------------------------------------------

  @impl true
  def init(opts) do
    dir = Keyword.get(opts, :data_dir, Application.get_env(:junderground, :data_dir, "data"))
    File.mkdir_p!(dir)
    path = Path.join(dir, "houses.dets")

    :dets.close(@table)

    {:ok, _} =
      :dets.open_file(@table,
        file: String.to_charlist(path),
        type: :set,
        auto_save: 2_000
      )

    log_seq =
      case :dets.lookup(@table, {:meta, :log_seq}) do
        [{{:meta, :log_seq}, n}] when is_integer(n) -> n
        _ -> 0
      end

    {:ok, %{log_seq: log_seq}}
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.close(@table)
    :ok
  end

  @impl true
  def handle_call({:append, record}, _from, state) do
    prior = head(record["handle"])

    case Record.validate(record, prior) do
      :unchanged ->
        {:reply, {:ok, :unchanged}, state}

      :ok ->
        n = state.log_seq + 1
        put(record, n)
        {:reply, {:ok, %{handle: record["handle"], seq: record["seq"]}}, %{state | log_seq: n}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:latest, handle}, _from, state) do
    case head(handle) do
      nil -> {:reply, {:error, :not_found}, state}
      head -> {:reply, {:ok, head}, state}
    end
  end

  def handle_call({:live, handle}, _from, state) do
    case head(handle) do
      nil -> {:reply, {:error, :not_found}, state}
      %{"tombstoned" => true} -> {:reply, {:error, :not_found}, state}
      head -> {:reply, {:ok, head}, state}
    end
  end

  def handle_call({:history, handle, since}, _from, state) do
    ms = [{{{:record, handle, :"$1"}, :"$2"}, [{:>=, :"$1", since}], [:"$2"]}]
    records = :dets.select(@table, ms) |> Enum.sort_by(& &1["seq"])
    {:reply, {:ok, records}, state}
  end

  def handle_call({:feed, since, limit}, _from, %{log_seq: top} = state) do
    {:reply, {:ok, collect(since, max(limit, 0), top)}, state}
  end

  def handle_call({:mirror, records}, _from, state) when is_list(records) do
    {results, state} =
      Enum.reduce(records, {[], state}, fn record, {acc, st} ->
        prior = head(record["handle"])

        case Record.validate(record, prior) do
          :unchanged ->
            {[{record["handle"], :unchanged} | acc], st}

          :ok ->
            n = st.log_seq + 1
            put(record, n)
            {[{record["handle"], :ok} | acc], %{st | log_seq: n}}

          {:error, reason} ->
            {[{record["handle"], reason} | acc], st}
        end
      end)

    {:reply, {:ok, Enum.reverse(results)}, state}
  end

  def handle_call(:count, _from, state) do
    count =
      :dets.foldl(
        fn
          {{:head, _handle}, _head}, acc -> acc + 1
          _other, acc -> acc
        end,
        0,
        @table
      )

    {:reply, count, state}
  end

  # ---- storage -------------------------------------------------------------

  defp head(handle) do
    case :dets.lookup(@table, {:head, handle}) do
      [{{:head, ^handle}, head}] -> head
      _ -> nil
    end
  end

  defp put(record, n) do
    handle = record["handle"]
    seq = record["seq"]

    head = %{
      "seq" => seq,
      "sig" => record["sig"],
      "pubkey" => Record.active_pubkey(record),
      "tombstoned" => Record.tombstone?(record),
      "fingerprint" => Junderground.Keys.fingerprint(record["pubkey"]),
      "record" => record
    }

    :dets.insert(@table, [
      {{:head, handle}, head},
      {{:record, handle, seq}, record},
      {{:log, n}, {handle, seq}},
      {{:meta, :log_seq}, n}
    ])
  end

  # The log is dense, so the feed is a walk over its numbers. A missing number
  # is skipped rather than ending the walk, which keeps a mirror correct after
  # a partial repair.
  defp collect(_since, limit, _top) when limit <= 0, do: []
  defp collect(since, _limit, top) when since >= top, do: []

  defp collect(since, limit, top) do
    last = min(since + limit, top)

    (since + 1)..last
    |> Enum.reduce([], fn n, acc ->
      with [{{:log, ^n}, {handle, seq}}] <- :dets.lookup(@table, {:log, n}),
           [{{:record, ^handle, ^seq}, record}] <-
             :dets.lookup(@table, {:record, handle, seq}) do
        [record | acc]
      else
        _ -> acc
      end
    end)
    |> Enum.reverse()
  end
end
