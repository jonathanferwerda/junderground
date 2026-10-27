defmodule Junderground.Rentals do
  @moduledoc """
  Time windows on a room, signed by the room's owner.

  A rental is how a house reserves a dial for an event — a rock show on
  December 23 from 6 to 10 — and how the switch knows when the doors are open.
  Tickets sold in the store are minted against the active rental and expire at
  its end; a room with rentals is closed outside them (the owner excepted, for
  setting up).

  Money, sku lists and the broadcast are jawnos' store and studio. This module
  never sees a price or a payment; it sees a window, a label and a capacity.
  """

  use GenServer

  alias Junderground.{Canonical, Keys}

  @table :junderground_rentals
  @format "junderground-rental"
  @version 1
  @slug ~r/^[a-z0-9][a-z0-9._-]{0,62}$/
  @max_window 12 * 3600
  @max_skew 3600

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def build(handle, room, pubkey, seq, start_at, end_at, fields \\ %{}) do
    Map.merge(
      %{
        "format" => @format,
        "version" => @version,
        "handle" => handle,
        "room" => room,
        "pubkey" => pubkey,
        "seq" => seq,
        "issued" => System.system_time(:second),
        "start" => start_at,
        "end" => end_at,
        "guest_start" => start_at,
        "guest_end" => end_at,
        "citizen" => handle,
        "label" => "",
        "event" => "",
        "sku" => "",
        "capacity" => 100,
        "fee" => 0,
        "currency" => "CAD",
        "guest_price" => 0,
        "guest_currency" => "CAD"
      },
      fields
    )
  end

  def create(record), do: GenServer.call(__MODULE__, {:create, record})
  def list(handle, room), do: GenServer.call(__MODULE__, {:list, handle, room})
  def active(handle, room), do: GenServer.call(__MODULE__, {:active, handle, room})
  def next(handle, room), do: GenServer.call(__MODULE__, {:next, handle, room})
  def current(handle, room), do: GenServer.call(__MODULE__, {:current, handle, room})

  @doc """
  The door for the next or active rental.

  `reserved` — a rental is ahead; `notice` — inside five minutes, tell the
  people without a ticket; `closing` — the last minute, no new non-ticketed
  join; `in_window` — the rental is on; `open` — nothing scheduled.
  """
  def door(handle, room), do: GenServer.call(__MODULE__, {:door, handle, room})

  @doc "Owner nil when the room has no rentals; the active one; or `:owner`."
  def open_for(handle, room, requester, role \\ "guest") do
    GenServer.call(__MODULE__, {:open_for, handle, room, requester, role})
  end

  @doc """
  Quote the switch's flat rental fee.

  The base fee is set by the administrator; the rate falls with **specificity**:
  the more non-wildcard constructs a room names, the less the rental costs.
  `blocks` is the number of contiguous blocks rented; it sets the duration, not
  the fee — a rental is a flat rate.
  """
  def quote(scope, blocks) when is_map(scope) and is_integer(blocks) and blocks > 0 do
    base = Application.get_env(:junderground, :rent_base_fee, 0)
    currency = Application.get_env(:junderground, :rent_currency, "CAD")
    block_seconds = Application.get_env(:junderground, :rent_block_seconds, 4 * 3600)
    rates = Application.get_env(:junderground, :rent_rate_percent, [100, 50, 25])

    non_wildcards = map_size(scope)
    index = min(max(non_wildcards, 1), length(rates)) - 1
    rate = Enum.at(rates, index, List.last(rates))
    fee = round(base * rate / 100)

    %{
      "non_wildcards" => non_wildcards,
      "blocks" => blocks,
      "block_seconds" => block_seconds,
      "seconds" => blocks * block_seconds,
      "rate_percent" => rate,
      "fee" => fee,
      "currency" => currency
    }
  end

  def cancel(handle, room, id), do: GenServer.call(__MODULE__, {:cancel, handle, room, id})

  # ---- server --------------------------------------------------------------

  @impl true
  def init(opts) do
    dir = Keyword.get(opts, :data_dir, Application.get_env(:junderground, :data_dir, "data"))
    File.mkdir_p!(dir)
    path = Path.join(dir, "rentals.dets")

    :dets.close(@table)

    {:ok, _} =
      :dets.open_file(@table, file: String.to_charlist(path), type: :set, auto_save: 2_000)

    {:ok, %{}}
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.close(@table)
    :ok
  end

  @impl true
  def handle_call({:create, record}, _from, state) do
    now = System.system_time(:second)
    head = head(record["handle"], record["room"])

    reply =
      with :ok <- validate(record, head, now),
           :ok <- no_overlap(record) do
        id = Canonical.sha256_hex(record["sig"])

        rental = %{
          "id" => id,
          "record" => record,
          "cancelled" => false
        }

        :dets.insert(@table, [
          {{:rental, record["handle"], record["room"], record["seq"]}, rental},
          {{:rental_head, record["handle"], record["room"]}, record}
        ])

        {:ok, view(rental)}
      end

    {:reply, reply, state}
  end

  def handle_call({:list, handle, room}, _from, state) do
    rentals =
      live(handle, room)
      |> Enum.sort_by(& &1["record"]["start"])
      |> Enum.map(&view/1)

    {:reply, {:ok, rentals}, state}
  end

  def handle_call({:active, handle, room}, _from, state) do
    now = System.system_time(:second)
    {:reply, {:ok, active_rental(handle, room, now) |> maybe_view()}, state}
  end

  def handle_call({:next, handle, room}, _from, state) do
    now = System.system_time(:second)
    {:reply, {:ok, maybe_view(next_rental(handle, room, now))}, state}
  end

  def handle_call({:door, handle, room}, _from, state) do
    now = System.system_time(:second)
    rental = active_rental(handle, room, now) || next_rental(handle, room, now)
    {:reply, door_view(rental, now), state}
  end

  def handle_call({:current, handle, room}, _from, state) do
    now = System.system_time(:second)

    current =
      active_rental(handle, room, now) || next_rental(handle, room, now)

    {:reply, {:ok, maybe_view(current)}, state}
  end

  def handle_call({:open_for, handle, room, requester, role}, _from, state) do
    now = System.system_time(:second)
    rentals = live(handle, room)

    reply =
      cond do
        rentals == [] ->
          {:ok, nil}

        (requester == handle or role == "citizen") and role == "citizen" ->
          case active_for(rentals, now, "citizen") do
            nil -> {:ok, :owner}
            rental -> {:ok, view(rental)}
          end

        true ->
          case active_for(rentals, now, role) do
            nil -> {:error, :not_open}
            rental -> {:ok, view(rental)}
          end
      end

    {:reply, reply, state}
  end

  def handle_call({:cancel, handle, room, id}, _from, state) do
    found =
      live(handle, room)
      |> Enum.find(&(&1["id"] == id))

    case found do
      nil ->
        {:reply, {:error, :not_found}, state}

      rental ->
        record = rental["record"]

        :dets.insert(@table, [
          {{:rental, handle, room, record["seq"]}, Map.put(rental, "cancelled", true)}
        ])

        {:reply, {:ok, view(Map.put(rental, "cancelled", true))}, state}
    end
  end

  # ---- validation ----------------------------------------------------------

  defp validate(record, head, now) do
    cond do
      record["format"] != @format ->
        {:error, :bad_format}

      record["version"] != @version ->
        {:error, :bad_version}

      not is_binary(record["handle"]) or not Regex.match?(@slug, record["handle"]) ->
        {:error, :bad_handle}

      not is_binary(record["room"]) or not Regex.match?(@slug, record["room"]) ->
        {:error, :bad_room}

      not Keys.valid_public_key?(record["pubkey"]) ->
        {:error, :bad_pubkey}

      not is_integer(record["seq"]) or record["seq"] < 1 ->
        {:error, :bad_seq}

      not is_integer(record["issued"]) ->
        {:error, :bad_issued}

      record["issued"] > now + @max_skew ->
        {:error, :future}

      not is_binary(record["sig"]) ->
        {:error, :bad_signature}

      not Keys.verify_record(record) ->
        {:error, :bad_signature}

      not is_integer(record["start"]) or not is_integer(record["end"]) ->
        {:error, :bad_window}

      record["end"] <= record["start"] ->
        {:error, :bad_window}

      record["end"] - record["start"] > @max_window ->
        {:error, :window_too_long}

      not is_integer(record["guest_start"]) or not is_integer(record["guest_end"]) ->
        {:error, :bad_guest_window}

      not (record["start"] <= record["guest_start"] and
             record["guest_start"] < record["guest_end"] and record["guest_end"] <= record["end"]) ->
        {:error, :bad_guest_window}

      not is_binary(record["citizen"]) or byte_size(record["citizen"]) > 64 ->
        {:error, :bad_citizen}

      not is_integer(record["fee"]) or record["fee"] < 0 ->
        {:error, :bad_fee}

      not is_integer(record["guest_price"]) or record["guest_price"] < 0 ->
        {:error, :bad_guest_price}

      not is_binary(record["currency"]) or not Regex.match?(~r/^[A-Z]{3}$/, record["currency"]) ->
        {:error, :bad_currency}

      not is_binary(record["guest_currency"]) or
          not Regex.match?(~r/^[A-Z]{3}$/, record["guest_currency"]) ->
        {:error, :bad_currency}

      not is_binary(record["label"]) or byte_size(record["label"]) > 200 ->
        {:error, :bad_label}

      not is_binary(record["event"]) or byte_size(record["event"]) > 64 ->
        {:error, :bad_event}

      not is_binary(record["sku"]) or byte_size(record["sku"]) > 64 ->
        {:error, :bad_sku}

      not is_integer(record["capacity"]) or record["capacity"] < 1 or record["capacity"] > 10_000 ->
        {:error, :bad_capacity}

      head == nil and record["seq"] != 1 ->
        {:error, :bad_first_seq}

      head != nil and record["seq"] != head["seq"] + 1 ->
        {:error, :gap}

      head != nil and record["prev"] != head["sig"] ->
        {:error, :broken_chain}

      head != nil and record["pubkey"] != head["pubkey"] ->
        {:error, :wrong_key}

      true ->
        :ok
    end
  end

  defp no_overlap(record) do
    overlaps =
      live(record["handle"], record["room"])
      |> Enum.any?(fn rental ->
        other = rental["record"]
        other["start"] < record["end"] and record["start"] < other["end"]
      end)

    if overlaps, do: {:error, :overlap}, else: :ok
  end

  # ---- storage -------------------------------------------------------------

  defp head(handle, room) do
    case :dets.lookup(@table, {:rental_head, handle, room}) do
      [{{:rental_head, ^handle, ^room}, record}] -> record
      _ -> nil
    end
  end

  defp live(handle, room) do
    :dets.select(@table, [
      {{{:rental, handle, room, :_}, :"$1"}, [], [:"$1"]}
    ])
    |> Enum.reject(& &1["cancelled"])
  end

  defp next_rental(handle, room, now) do
    live(handle, room)
    |> Enum.filter(&(&1["record"]["start"] > now))
    |> Enum.sort_by(& &1["record"]["start"])
    |> List.first()
  end

  defp active_rental(handle, room, now) do
    live(handle, room)
    |> Enum.find(fn rental ->
      record = rental["record"]
      record["start"] <= now and now < record["end"]
    end)
  end

  # The citizen and residents use the whole rented block; a guest only the
  # guest window the citizen chose inside it.
  defp active_for(rentals, now, role) do
    Enum.find(rentals, fn rental ->
      record = rental["record"]

      {from, until} =
        if role == "guest",
          do: {record["guest_start"], record["guest_end"]},
          else: {record["start"] - 300, record["end"]}

      from <= now and now < until
    end)
  end

  defp door_view(nil, _now), do: %{"state" => "open"}

  defp door_view(rental, now) do
    record = rental["record"]
    start_at = record["start"]
    end_at = record["end"]

    state =
      cond do
        now < start_at - 300 -> "reserved"
        now < start_at - 60 -> "notice"
        now < start_at -> "closing"
        now < end_at -> "in_window"
        true -> "open"
      end

    %{
      "state" => state,
      "id" => rental["id"],
      "start" => start_at,
      "end" => end_at,
      "guest_start" => record["guest_start"],
      "guest_end" => record["guest_end"],
      "notify_at" => start_at - 300,
      "door_closed_at" => start_at - 60,
      "starts_at" => start_at
    }
  end

  defp maybe_view(nil), do: nil
  defp maybe_view(rental), do: view(rental)

  defp view(rental) do
    record = rental["record"]

    %{
      "id" => rental["id"],
      "handle" => record["handle"],
      "room" => record["room"],
      "start" => record["start"],
      "end" => record["end"],
      "guest_start" => record["guest_start"],
      "guest_end" => record["guest_end"],
      "citizen" => record["citizen"],
      "label" => record["label"],
      "fee" => record["fee"],
      "currency" => record["currency"],
      "guest_price" => record["guest_price"],
      "guest_currency" => record["guest_currency"],
      "event" => record["event"],
      "sku" => record["sku"],
      "capacity" => record["capacity"],
      "cancelled" => rental["cancelled"],
      "record" => record
    }
  end
end
