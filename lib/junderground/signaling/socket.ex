defmodule Junderground.Signaling.Socket do
  @moduledoc """
  One room's socket for one house.

  The grant was verified before the upgrade; the socket re-checks it every
  fifteen seconds so a suspension (which bumps the admission epoch) closes the
  channel without waiting for the client to leave.
  """

  @behaviour WebSock

  alias Junderground.{Rooms, Signaling, Turn}
  alias Junderground.Signaling.Protocol

  @recheck 15_000

  @impl true
  def init(state) do
    room = room_key(state)
    {:ok, _} = Signaling.join(room, %{jti: state.jti, subject: state.subject})

    Signaling.deliver(room, %{
      "type" => "join",
      "from" => state.subject,
      "subject" => state.subject,
      "at" => System.system_time(:second)
    })

    Process.send_after(self(), :recheck, @recheck)

    hello = %{
      "type" => "hello",
      "room" => room,
      "subject" => state.subject,
      "role" => state.role,
      "caps" => state.caps,
      "peers" => Signaling.count(room),
      "ice_servers" => Turn.credentials(state.subject)
    }

    {:push, {:text, JSON.encode!(hello)}, state}
  end

  @impl true
  def handle_in({text, [opcode: :text]}, state) do
    case Protocol.decode(text) do
      {:ok, msg} ->
        case Protocol.envelope(msg, state) do
          {:ok, envelope} -> relay(envelope, state)
          {:error, reason} -> {:push, {:text, error_json(reason)}, state}
        end

      {:error, reason} ->
        {:push, {:text, error_json(reason)}, state}
    end
  end

  def handle_in({_data, _opts}, state) do
    {:push, {:text, error_json("binary frames are not used")}, state}
  end

  @impl true
  def handle_info({:signal, envelope}, state) do
    {:push, {:text, JSON.encode!(envelope)}, state}
  end

  def handle_info(:recheck, state) do
    case Rooms.verify_grant(state.token) do
      {:ok, _payload} ->
        Process.send_after(self(), :recheck, @recheck)
        {:ok, state}

      {:error, _reason} ->
        {:stop, :normal, state}
    end
  end

  def handle_info(_other, state), do: {:ok, state}

  @impl true
  def handle_control({:ping, data}, state), do: {:push, {:pong, data}, state}
  def handle_control(_frame, state), do: {:ok, state}

  @impl true
  def terminate(_reason, state) do
    Signaling.deliver(room_key(state), %{
      "type" => "leave",
      "from" => state.subject,
      "subject" => state.subject,
      "at" => System.system_time(:second)
    })

    :ok
  end

  defp relay(envelope, state) do
    room = room_key(state)

    case envelope["to"] do
      nil ->
        Signaling.deliver(room, envelope)
        {:ok, state}

      jti ->
        if Signaling.deliver_to(room, jti, envelope) == 0 do
          {:push, {:text, error_json("no such peer")}, state}
        else
          {:ok, state}
        end
    end
  end

  defp room_key(state), do: state.handle <> "/" <> state.room
  defp error_json(reason), do: JSON.encode!(%{"type" => "error", "error" => reason})
end
