defmodule Junderground.Signaling do
  @moduledoc """
  The room's signaling channel: offers, answers and ICE, relayed.

  One WebSocket per joined house, keyed by `handle/room`. A message is stamped
  with the sender's subject and grant id, so a peer always knows who spoke and
  a client cannot claim to be someone else. Media never comes through here; the
  switch only routes the handshake.

  The registry entry dies with the socket process, so a dropped connection
  leaves the room immediately. Presence is still the HTTP roster; this channel
  reports `join` and `leave` alongside it.
  """

  @registry __MODULE__.Registry

  def child_spec(_opts) do
    Registry.child_spec(keys: :duplicate, name: @registry)
  end

  @doc "Register this socket in its room. Called once per connection."
  def join(room, meta) do
    Registry.register(@registry, room, meta)
  end

  @doc "How many sockets (houses) are joined to the room."
  def count(room), do: length(Registry.lookup(@registry, room))

  @doc "Send an envelope to every other socket in the room."
  def deliver(room, envelope) do
    Registry.dispatch(@registry, room, fn entries ->
      for {pid, _meta} <- entries, pid != self() do
        send(pid, {:signal, envelope})
      end
    end)
  end

  @doc "Send an envelope to one socket by its grant id. Returns how many matched."
  def deliver_to(room, jti, envelope) do
    entries = Registry.lookup(@registry, room)

    sent =
      Enum.count(entries, fn {pid, meta} ->
        if meta[:jti] == jti and pid != self() do
          send(pid, {:signal, envelope})
          true
        else
          false
        end
      end)

    sent
  end

  @doc "The sockets in a room, as `%{jti, subject}` (no addresses, no people map)."
  def peers(room) do
    @registry |> Registry.lookup(room) |> Enum.map(fn {_pid, meta} -> Map.take(meta, [:jti, :subject]) end)
  end
end

defmodule Junderground.Signaling.Protocol do
  @moduledoc """
  What a signaling frame may say.

  The client's own `from` is ignored: the socket stamps the subject and grant
  id it verified at connect time. Only the four kinds below pass, only the
  fields they need are copied, and the whole envelope is capped.
  """

  @max_bytes 32_768
  @kinds ~w(offer answer ice bye)

  def max_bytes, do: @max_bytes
  def kinds, do: @kinds

  def decode(text) when is_binary(text) do
    cond do
      byte_size(text) > @max_bytes ->
        {:error, "frame too large"}

      true ->
        case JSON.decode(text) do
          {:ok, msg} when is_map(msg) -> {:ok, msg}
          _ -> {:error, "not a JSON object"}
        end
    end
  end

  def decode(_other), do: {:error, "binary frames are not used"}

  @doc "Turn a client message into the envelope relayed to the room."
  def envelope(msg, sender) do
    kind = msg["type"]

    cond do
      kind not in @kinds ->
        {:error, "unknown type"}

      kind == "bye" ->
        finish(%{"type" => "bye"}, msg, sender)

      kind == "ice" ->
        cond do
          is_nil(msg["candidate"]) -> {:error, "missing candidate"}
          byte_size(JSON.encode!(msg["candidate"])) > 4096 -> {:error, "candidate too large"}
          true -> finish(%{"type" => "ice", "candidate" => msg["candidate"]}, msg, sender)
        end

      true ->
        cond do
          not is_binary(msg["sdp"]) or byte_size(msg["sdp"]) > 24_576 ->
            {:error, "missing sdp"}

          true ->
            finish(
              %{"type" => kind, "sdp" => msg["sdp"]},
              msg,
              sender
            )
        end
    end
  end

  defp finish(base, msg, sender) do
    envelope =
      base
      |> Map.put("from", sender.subject)
      |> Map.put("from_jti", sender.jti)
      |> Map.put("at", System.system_time(:second))
      |> maybe_to(msg)

    if byte_size(JSON.encode!(envelope)) > @max_bytes do
      {:error, "frame too large"}
    else
      {:ok, envelope}
    end
  end

  defp maybe_to(envelope, msg) do
    case msg["to"] do
      to when is_binary(to) and byte_size(to) > 0 -> Map.put(envelope, "to", to)
      _ -> envelope
    end
  end
end
