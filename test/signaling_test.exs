defmodule Junderground.SignalingTest do
  use ExUnit.Case, async: false

  import Bitwise

  alias Junderground.{Admission, Directory, Keys, Record, Rooms, ServerKey, Token}

  setup do
    dir = Path.join(System.tmp_dir!(), "jg-signal-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Application.put_env(:junderground, :data_dir, dir)
    ServerKey.reset()

    start_supervised!({Admission, data_dir: dir})
    start_supervised!({Directory, data_dir: dir})
    start_supervised!({Junderground.Lexicon, data_dir: dir})
    start_supervised!({Junderground.Rentals, data_dir: dir})
    start_supervised!({Rooms, data_dir: dir})
    start_supervised!(Junderground.Presence)
    start_supervised!(Junderground.Signaling)

    port = free_port()
    start_supervised!({Bandit, plug: Junderground.Router, port: port, startup_log: false})

    on_exit(fn ->
      Application.put_env(:junderground, :data_dir, "tmp/test-data")
      ServerKey.reset()
      File.rm_rf(dir)
    end)

    {pub, priv} = Keys.generate()

    house =
      Record.build("register", "alpha", pub, 1, %{"name" => "Alpha"})
      |> Keys.sign_record(priv)

    {:ok, _} = Directory.register(house)
    {:ok, _} = Admission.decide("alpha", "approved", "test", "", 0)

    room =
      Rooms.build("alpha", "lobby", pub, 1, %{"policy" => "open"})
      |> Keys.sign_record(priv)

    {:ok, _} = Rooms.register(room)

    {:ok, one} = Rooms.grant("alpha", "lobby", %{handle: "alpha"}, %{"caps" => ["join"]})
    {:ok, two} = Rooms.grant("alpha", "lobby", %{handle: "alpha"}, %{"caps" => ["join"]})

    %{port: port, one: one, two: two}
  end

  test "a grant opens a socket; the room relays offers, answers and ICE", %{
    port: port,
    one: one,
    two: two
  } do
    a = connect(port, one["grant"])
    {hello, a} = recv_text(a)
    hello = JSON.decode!(hello)
    assert hello["type"] == "hello"
    assert hello["subject"] == "alpha"
    assert hello["room"] == "alpha/lobby"
    assert hello["ice_servers"] == []
    assert is_binary(hello["jti"])

    b = connect(port, two["grant"])
    {hello_b, b} = recv_text(b)
    assert JSON.decode!(hello_b)["peers"] == 2

    {join, a} = recv_text(a)
    join = JSON.decode!(join)
    assert join["type"] == "join"
    assert join["from_jti"] == JSON.decode!(hello_b)["jti"]

    send_text(a, JSON.encode!(%{"type" => "offer", "sdp" => "v=0"}))
    {offer, b} = recv_text(b)
    assert %{"type" => "offer", "from" => "alpha", "sdp" => "v=0"} = JSON.decode!(offer)

    # the sender never hears its own message
    assert {:error, :timeout} = :gen_tcp.recv(a.sock, 0, 300)

    {:ok, payload} = Token.verify(two["grant"], ServerKey.public_b64())
    send_text(a, JSON.encode!(%{"type" => "ice", "candidate" => "c", "to" => payload["jti"]}))
    {ice, b} = recv_text(b)
    assert %{"type" => "ice", "candidate" => "c", "from" => "alpha"} = JSON.decode!(ice)

    send_text(a, JSON.encode!(%{"type" => "video", "want" => "on", "to" => payload["jti"]}))
    {video, b} = recv_text(b)
    assert %{"type" => "video", "want" => "on", "from" => "alpha"} = JSON.decode!(video)

    send_text(a, JSON.encode!(%{"type" => "video", "want" => "maybe"}))
    {bad_video, a} = recv_text(a)
    assert JSON.decode!(bad_video)["type"] == "error"

    send_text(a, JSON.encode!(%{"type" => "broadcast", "on" => "yes",
      "streams" => [%{"id" => "s1", "label" => "Studio 1", "kind" => "audio"}]}))
    {cast, b} = recv_text(b)
    assert %{"type" => "broadcast", "on" => "yes"} = JSON.decode!(cast)
    assert [%{"id" => "s1", "label" => "Studio 1", "kind" => "audio"}] = JSON.decode!(cast)["streams"]

    send_text(a, JSON.encode!(%{"type" => "broadcast", "streams" => [%{"id" => "s1", "label" => "x", "kind" => "smell"}]}))
    {bad_cast, a} = recv_text(a)
    assert JSON.decode!(bad_cast)["type"] == "error"

    send_text(b, JSON.encode!(%{"type" => "nonsense"}))
    {err, b} = recv_text(b)
    assert JSON.decode!(err)["type"] == "error"

    :gen_tcp.close(b.sock)
    {leave, a} = recv_text(a)
    assert JSON.decode!(leave)["type"] == "leave"

    :gen_tcp.close(a.sock)
  end

  test "a socket cannot claim to be someone else", %{port: port, one: one} do
    a = connect(port, one["grant"])
    {_hello, a} = recv_text(a)

    send_text(a, JSON.encode!(%{"type" => "offer", "sdp" => "v=0", "from" => "mallory"}))
    assert {:error, :timeout} = :gen_tcp.recv(a.sock, 0, 300)

    send_text(a, JSON.encode!(%{"type" => "ice", "candidate" => "c", "to" => "nobody"}))
    {err, a} = recv_text(a)
    assert JSON.decode!(err)["error"] == "no such peer"

    :gen_tcp.close(a.sock)
  end

  test "the handshake is refused without a valid grant", %{port: port} do
    refute handshake(port, "not-a-token") =~ "101"
    refute handshake(port, nil) =~ "101"
  end

  # ---- a very small WebSocket client ------------------------------------

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp handshake(port, grant) do
    {:ok, sock} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw], 2000)

    query = if grant, do: "?grant=" <> URI.encode_www_form(grant), else: ""

    request = [
      "GET /v1/rooms/alpha/lobby/ws",
      query,
      " HTTP/1.1\r\nHost: 127.0.0.1:",
      Integer.to_string(port),
      "\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: ",
      Base.encode64(:crypto.strong_rand_bytes(16)),
      "\r\nSec-WebSocket-Version: 13\r\n\r\n"
    ]

    :ok = :gen_tcp.send(sock, request)
    {:ok, response} = :gen_tcp.recv(sock, 0, 2000)
    :gen_tcp.close(sock)
    response
  end

  defp connect(port, grant) do
    {:ok, sock} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw], 2000)

    request = [
      "GET /v1/rooms/alpha/lobby/ws?grant=",
      URI.encode_www_form(grant),
      " HTTP/1.1\r\nHost: 127.0.0.1:",
      Integer.to_string(port),
      "\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: ",
      Base.encode64(:crypto.strong_rand_bytes(16)),
      "\r\nSec-WebSocket-Version: 13\r\n\r\n"
    ]

    :ok = :gen_tcp.send(sock, request)
    {head, rest} = read_headers(sock, "")
    assert head =~ "101"
    %{sock: sock, buf: rest}
  end

  defp read_headers(sock, acc) do
    case :binary.split(acc, "\r\n\r\n") do
      [head, rest] ->
        {head, rest}

      _ ->
        {:ok, data} = :gen_tcp.recv(sock, 0, 2000)
        read_headers(sock, acc <> data)
    end
  end

  defp send_text(client, text) do
    mask = :crypto.strong_rand_bytes(4)
    masked = mask_bytes(text, mask)
    len = byte_size(text)

    header =
      case len do
        n when n < 126 -> <<1::1, 0::3, 1::4, 1::1, n::7>>
        n when n < 65_536 -> <<1::1, 0::3, 1::4, 1::1, 126::7, n::16>>
        n -> <<1::1, 0::3, 1::4, 1::1, 127::7, n::64>>
      end

    :ok = :gen_tcp.send(client.sock, [header, mask, masked])
  end

  defp mask_bytes(payload, mask) do
    payload
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.map(fn {byte, i} -> bxor(byte, :binary.at(mask, rem(i, 4))) end)
    |> :binary.list_to_bin()
  end

  defp recv_text(client) do
    {opcode, payload, client} = recv_frame(client)
    assert opcode == 1
    {payload, client}
  end

  defp recv_frame(client) do
    {<<first, second>>, client} = need(client, 2)
    len = second &&& 0x7F

    {len, client} =
      case len do
        126 ->
          {<<l::16>>, client} = need(client, 2)
          {l, client}

        127 ->
          {<<l::64>>, client} = need(client, 8)
          {l, client}

        n ->
          {n, client}
      end

    {payload, client} = need(client, len)
    {first &&& 0x0F, payload, client}
  end

  defp need(%{buf: buf} = client, n) when byte_size(buf) >= n do
    <<chunk::binary-size(n), rest::binary>> = buf
    {chunk, %{client | buf: rest}}
  end

  defp need(client, n) do
    {:ok, data} = :gen_tcp.recv(client.sock, 0, 2000)
    need(%{client | buf: client.buf <> data}, n)
  end
end
