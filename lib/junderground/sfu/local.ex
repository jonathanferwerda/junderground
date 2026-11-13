defmodule Junderground.Sfu.Local do
  @moduledoc """
  The switch's private SFU bookkeeping, in `data/sfu.dets`.

  Grants are stateless: a `JG1` token verifies from its signature alone, so the
  reconciler cannot ask "which grants are live by `jti`?" without a local
  record. At every successful `/sfu/token` the switch therefore stores the
  verified grant payload (jti, room key, room, expiry, epoch, role, caps,
  subject) and the opaque-room-to-room map in this table. The table never
  leaves the process and never goes to the media server.

  Expired rows are dropped whenever a grant is remembered and at the start of
  every reconciler sweep. DETS table names are global, so tests for this module
  are `async: false`.
  """

  use GenServer

  @table :junderground_sfu

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Store one verified grant and its opaque room. Cleans expired rows first."
  def remember(entry), do: GenServer.call(__MODULE__, {:remember, entry})

  @doc "Drop one grant row (the opaque room mapping stays until it is unused)."
  def forget(jti), do: GenServer.call(__MODULE__, {:forget, jti})

  @doc "Every stored grant row."
  def grants, do: GenServer.call(__MODULE__, :grants)

  @doc "Every opaque-room row."
  def rooms, do: GenServer.call(__MODULE__, :rooms)

  @doc "The `handle/room` a stored opaque name belongs to."
  def room_for(opaque), do: GenServer.call(__MODULE__, {:room_for, opaque})

  @doc "Delete expired grants and unused room rows."
  def clean(now \\ System.system_time(:second)), do: GenServer.call(__MODULE__, {:clean, now})

  @impl true
  def init(opts) do
    dir = Keyword.get(opts, :data_dir, Application.get_env(:junderground, :data_dir, "data"))
    File.mkdir_p!(dir)
    path = Path.join(dir, "sfu.dets")

    :dets.close(@table)

    {:ok, _} =
      :dets.open_file(@table,
        file: String.to_charlist(path),
        type: :set,
        auto_save: 2_000
      )

    {:ok, %{}}
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.close(@table)
    :ok
  end

  @impl true
  def handle_call({:remember, entry}, _from, state) when is_map(entry) do
    jti = entry["jti"]
    opaque = entry["opaque"]
    room = entry["room"]

    reply =
      if is_binary(jti) and is_binary(opaque) and is_binary(room) do
        :dets.insert(@table, {{:grant, jti}, entry})

        :dets.insert(
          @table,
          {{:room, opaque},
           %{"opaque" => opaque, "room" => room, "room_key" => entry["room_key"]}}
        )

        clean_now(System.system_time(:second))
        :ok
      else
        {:error, :bad_entry}
      end

    {:reply, reply, state}
  end

  def handle_call({:remember, _entry}, _from, state), do: {:reply, {:error, :bad_entry}, state}

  def handle_call({:forget, jti}, _from, state) do
    if is_binary(jti), do: :dets.delete(@table, {:grant, jti})
    {:reply, :ok, state}
  end

  def handle_call(:grants, _from, state) do
    rows = :dets.select(@table, [{{{:grant, :"$1"}, :"$2"}, [], [:"$2"]}])
    {:reply, rows, state}
  end

  def handle_call(:rooms, _from, state) do
    rows = :dets.select(@table, [{{{:room, :"$1"}, :"$2"}, [], [:"$2"]}])
    {:reply, rows, state}
  end

  def handle_call({:room_for, opaque}, _from, state) do
    reply =
      case :dets.lookup(@table, {:room, opaque}) do
        [{{:room, ^opaque}, row}] -> row["room"]
        _ -> nil
      end

    {:reply, reply, state}
  end

  def handle_call({:clean, now}, _from, state) do
    clean_now(now)
    {:reply, :ok, state}
  end

  defp clean_now(now) do
    grants = :dets.select(@table, [{{{:grant, :"$1"}, :"$2"}, [], [:"$2"]}])

    expired = Enum.filter(grants, &(not is_integer(&1["exp"]) or &1["exp"] <= now))
    Enum.each(expired, fn row -> :dets.delete(@table, {:grant, row["jti"]}) end)

    live = grants |> Enum.reject(&(&1 in expired)) |> MapSet.new(& &1["opaque"])

    :dets.select(@table, [{{{:room, :"$1"}, :"$2"}, [], [:"$2"]}])
    |> Enum.each(fn row ->
      unless MapSet.member?(live, row["opaque"]) do
        :dets.delete(@table, {:room, row["opaque"]})
      end
    end)

    :ok
  end
end
