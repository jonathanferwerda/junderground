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
        "label" => "",
        "event" => "",
        "sku" => "",
        "capacity" => 100
      },
      fields
    )
  end

  def create(record), do: GenServer.call(__MODULE__, {:create, record})
  def list(handle, room), do: GenServer.call(__MODULE__, {:list, handle, room})
  def active(handle, room), do: GenServer.call(__MODULE__, {:active, handle, room})
  def next(handle, room), do: GenServer.call(__MODULE__, {:next, handle, room})

  @doc "Owner nil when the room has no rentals; the active one; or `:owner`."
  def open_for(handle, room, requester) do
    GenServer.call(__MODULE__, {:open_for, handle, room, requester})
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

    next =
      live(handle, room)
      |> Enum.filter(&(&1["record"]["start"] > now))
      |> Enum.sort_by(& &1["record"]["start"])
      |> List.first()

    {:reply, {:ok, maybe_view(next)}, state}
  end

  def handle_call({:open_for, handle, room, requester}, _from, state) do
    now = System.system_time(:second)
    rentals = live(handle, room)

    reply =
      cond do
        rentals == [] ->
          {:ok, nil}

        requester == handle ->
          case active_rental(handle, room, now) do
            nil -> {:ok, :owner}
            rental -> {:ok, view(rental)}
          end

        true ->
          case active_rental(handle, room, now) do
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

  defp active_rental(handle, room, now) do
    live(handle, room)
    |> Enum.find(fn rental ->
      record = rental["record"]
      record["start"] <= now and now < record["end"]
    end)
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
      "label" => record["label"],
      "event" => record["event"],
      "sku" => record["sku"],
      "capacity" => record["capacity"],
      "cancelled" => rental["cancelled"]
    }
  end
end
