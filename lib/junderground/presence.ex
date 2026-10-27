defmodule Junderground.Presence do
  @moduledoc """
  Who is in a room right now.

  Presence is deliberately tiny: a handle (the grant's subject), the
  capabilities it holds, when it arrived and when its heartbeat lapses. No
  address, no device, no relationship — the switch does not know who you like.

  A client joins with the grant it already holds; the entry is keyed by the
  grant's `jti`, so a refreshed token is a fresh entry and a revoked one can be
  turned away. Entries expire on their own, so a crashed client disappears.
  """

  use GenServer

  @default_ttl 120

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def join(room, subject, caps, jti, ttl \\ @default_ttl, opts \\ %{}) do
    GenServer.call(__MODULE__, {:join, room, subject, caps, jti, ttl, opts})
  end

  def leave(room, presence_id, subject \\ nil) do
    GenServer.call(__MODULE__, {:leave, room, presence_id, subject})
  end

  def roster(room), do: GenServer.call(__MODULE__, {:roster, room})

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:join, room, subject, caps, jti, ttl, opts}, _from, state) do
    now = System.system_time(:second)
    state = prune(state, now)
    id = presence_id(room, subject, jti)
    ttl = if is_integer(ttl) and ttl > 0, do: min(ttl, 600), else: @default_ttl

    entry = %{
      "id" => id,
      "subject" => subject,
      "caps" => caps,
      "joined" => now,
      "expires" => now + ttl,
      "jti" => jti,
      "ticketed" => opts["ticketed"] == true,
      "notify_at" => integer(opts["notify_at"]),
      "evict_at" => integer(opts["evict_at"])
    }

    room_state = Map.get(state, room, %{})
    state = Map.put(state, room, Map.put(room_state, id, entry))
    {:reply, {:ok, entry, roster_of(state, room)}, state}
  end

  def handle_call({:leave, room, presence_id, subject}, _from, state) do
    entries = Map.get(state, room, %{})

    case Map.get(entries, presence_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      entry ->
        if is_nil(subject) or entry["subject"] == subject do
          {:reply, :ok, Map.put(state, room, Map.delete(entries, presence_id))}
        else
          {:reply, {:error, :forbidden}, state}
        end
    end
  end

  def handle_call({:roster, room}, _from, state) do
    state = prune(state, System.system_time(:second))
    {:reply, {:ok, roster_of(state, room)}, state}
  end

  defp roster_of(state, room) do
    state
    |> Map.get(room, %{})
    |> Map.values()
    |> Enum.map(fn entry ->
      %{
        "presence_id" => entry["id"],
        "subject" => entry["subject"],
        "caps" => entry["caps"],
        "joined" => entry["joined"],
        "expires" => entry["expires"],
        "ticketed" => entry["ticketed"],
        "notify_at" => entry["notify_at"],
        "evict_at" => entry["evict_at"]
      }
    end)
    |> Enum.sort_by(& &1["joined"])
  end

  # An entry whose eviction time has passed is gone: a non-ticketed person is
  # out when the rental starts.
  defp prune(state, now) do
    Map.new(state, fn {room, entries} ->
      live =
        Map.reject(entries, fn {_id, entry} ->
          entry["expires"] <= now or
            (entry["evict_at"] > 0 and entry["evict_at"] <= now)
        end)

      {room, live}
    end)
  end

  defp integer(value) when is_integer(value), do: value
  defp integer(_value), do: 0

  defp presence_id(room, subject, jti) do
    :crypto.hash(:sha256, Enum.join([room, subject, jti], <<0x1F>>))
    |> Base.encode16(case: :lower)
    |> String.slice(0, 24)
  end
end
