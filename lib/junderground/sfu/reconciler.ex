defmodule Junderground.Sfu.Reconciler do
  @moduledoc """
  The 30-second sweep of SFU participants against the grants the switch knows.

  Grants are stateless, so this process compares two things it owns: the grant
  rows `Sfu.Local` recorded at token mint, and LiveKit's `ListParticipants`.
  A participant whose `jti` is missing from the local map, expired, revoked,
  issued under a stale admission epoch, or closed by the room's door is
  removed. The switch does not need the SFU to verify a grant; it only needs a
  short admin token and the opaque room name.

  `Rooms.recheck/1` is the authoritative re-check (it runs the same signature
  rules the socket uses, minus the signature that was verified at mint).
  `sweep/1` takes injectable `list` and `remove` functions for tests.
  """

  use GenServer

  alias Junderground.{Rooms, Sfu}
  alias Junderground.Sfu.{Client, Local}

  @interval 30_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Run one sweep now. Options: `list: fun/1`, `remove: fun/2`."
  def sweep_now(opts \\ []), do: sweep(opts)

  @doc """
  One reconciliation pass.

  Expired rows are cleaned first. Grants are grouped by opaque room, then each
  room's connected identities are compared with the still-valid grant ids.
  Every failure mode is local; a failed `ListParticipants` leaves the room
  untouched until the next sweep.
  """
  def sweep(opts \\ []) do
    if Sfu.enabled?() and Process.whereis(Local) do
      now = System.system_time(:second)
      Local.clean(now)

      list = Keyword.get(opts, :list, &Client.list_participants/1)
      remove = Keyword.get(opts, :remove, &Client.remove_participant/2)

      Local.grants()
      |> Enum.filter(&(is_integer(&1["exp"]) and &1["exp"] > now))
      |> Enum.group_by(& &1["opaque"])
      |> Enum.each(fn {opaque, rows} ->
        case list.(opaque) do
          {:ok, identities} ->
            valid =
              rows
              |> Enum.filter(fn row -> is_binary(row["opaque"]) and Rooms.recheck(row) == :ok end)
              |> MapSet.new(& &1["jti"])

            Enum.each(identities, fn identity ->
              unless MapSet.member?(valid, identity), do: remove.(opaque, identity)
            end)

          _ ->
            :ok
        end
      end)
    end

    :ok
  rescue
    _ -> :ok
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, @interval)
    Process.send_after(self(), :sweep, interval)
    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    Process.send_after(self(), :sweep, state.interval)
    {:ok, state}
  end
end
