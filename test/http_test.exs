defmodule Junderground.HttpTest do
  use ExUnit.Case, async: false

  alias Junderground.{Admission, Auth, Directory, Keys, Nonces, Record, Rooms, Router, ServerKey}

  setup do
    dir = Path.join(System.tmp_dir!(), "jg-http-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Application.put_env(:junderground, :data_dir, dir)
    ServerKey.reset()

    start_supervised!(Nonces)
    start_supervised!({Admission, data_dir: dir})
    start_supervised!({Directory, data_dir: dir})
    start_supervised!({Junderground.Rentals, data_dir: dir})
    start_supervised!({Rooms, data_dir: dir})

    on_exit(fn ->
      Application.put_env(:junderground, :data_dir, "tmp/test-data")
      ServerKey.reset()
      File.rm_rf(dir)
    end)

    {pub, priv} = Keys.generate()
    %{pub: pub, priv: priv}
  end

  defp call(conn), do: Router.call(conn, [])

  defp signed(conn, body, handle, priv) do
    signed(
      conn,
      body,
      handle,
      priv,
      Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    )
  end

  defp signed(conn, body, handle, priv, nonce) do
    timestamp = Integer.to_string(System.system_time(:second))

    signature =
      Auth.message(conn, body, timestamp, nonce)
      |> then(&:crypto.sign(:eddsa, :none, &1, [priv, :ed25519]))
      |> Base.encode64()

    conn
    |> Plug.Conn.put_req_header("x-jg-handle", handle)
    |> Plug.Conn.put_req_header("x-jg-timestamp", timestamp)
    |> Plug.Conn.put_req_header("x-jg-nonce", nonce)
    |> Plug.Conn.put_req_header("x-jg-signature", signature)
  end

  test "meta advertises the switch's public key" do
    conn = call(Plug.Test.conn(:get, "/v1/meta"))
    assert conn.status == 200
    assert %{"pubkey" => pub} = JSON.decode!(conn.resp_body)
    assert pub == ServerKey.public_b64()
  end

  test "a house registers and is looked up", %{pub: pub, priv: priv} do
    record =
      Record.build("register", "alpha", pub, 1, %{"name" => "Alpha"})
      |> Keys.sign_record(priv)

    body = JSON.encode!(record)
    conn = call(Plug.Test.conn(:post, "/v1/houses", body))
    assert conn.status == 201

    # a fresh registration is pending and is not listed to anyone else
    conn = call(Plug.Test.conn(:get, "/v1/houses/alpha"))
    assert conn.status == 404

    assert {:ok, _} = Admission.decide("alpha", "approved", "test", "", 0)

    conn = call(Plug.Test.conn(:get, "/v1/houses/alpha"))
    assert conn.status == 200
    assert %{"record" => %{"handle" => "alpha", "name" => "Alpha"}} = JSON.decode!(conn.resp_body)
  end

  test "a signed request buys a room grant", %{pub: pub, priv: priv} do
    house =
      Record.build("register", "alpha", pub, 1, %{"name" => "Alpha"})
      |> Keys.sign_record(priv)

    assert {:ok, _} = Directory.register(house)
    assert {:ok, _} = Admission.decide("alpha", "approved", "test", "", 0)

    room = Rooms.build("alpha", "lobby", pub, 1, %{"policy" => "open"}) |> Keys.sign_record(priv)
    assert {:ok, _} = Rooms.register(room)

    body = JSON.encode!(%{"caps" => ["join", "publish_audio"]})

    conn =
      Plug.Test.conn(:post, "/v1/rooms/alpha/lobby/token", body)
      |> signed(body, "alpha", priv)
      |> call()

    assert conn.status == 200
    assert %{"grant" => grant, "caps" => caps} = JSON.decode!(conn.resp_body)
    assert "join" in caps
    assert {:ok, _} = Rooms.verify_grant(grant)
  end

  test "a request with no signature is refused", %{pub: pub, priv: priv} do
    house =
      Record.build("register", "alpha", pub, 1, %{"name" => "Alpha"})
      |> Keys.sign_record(priv)

    assert {:ok, _} = Directory.register(house)

    conn = call(Plug.Test.conn(:post, "/v1/rooms/alpha/lobby/token", JSON.encode!(%{})))
    assert conn.status == 401
  end

  test "a repeated nonce is a replay", %{pub: pub, priv: priv} do
    house =
      Record.build("register", "alpha", pub, 1, %{"name" => "Alpha"})
      |> Keys.sign_record(priv)

    assert {:ok, _} = Directory.register(house)
    assert {:ok, _} = Admission.decide("alpha", "approved", "test", "", 0)
    room = Rooms.build("alpha", "lobby", pub, 1, %{"policy" => "open"}) |> Keys.sign_record(priv)
    assert {:ok, _} = Rooms.register(room)

    body = JSON.encode!(%{"caps" => ["join"]})
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    first =
      Plug.Test.conn(:post, "/v1/rooms/alpha/lobby/token", body)
      |> signed(body, "alpha", priv, nonce)
      |> call()

    assert first.status == 200

    # the same nonce a second time is a replay, even on a fresh request
    second =
      Plug.Test.conn(:post, "/v1/rooms/alpha/lobby/token", body)
      |> signed(body, "alpha", priv, nonce)
      |> call()

    assert second.status == 409
  end

  test "the dial finds an advertised room by construct", %{pub: pub, priv: priv} do
    house =
      Record.build("register", "alpha", pub, 1, %{"name" => "Alpha"})
      |> Keys.sign_record(priv)

    assert {:ok, _} = Directory.register(house)
    assert {:ok, _} = Admission.decide("alpha", "approved", "test", "", 0)

    dial = %{"communities" => "harbour", "clubs" => "chess"}

    room =
      Rooms.build("alpha", "lobby", pub, 1, %{
        "policy" => "open",
        "advertised" => "yes",
        "constructs" => dial
      })
      |> Keys.sign_record(priv)

    assert {:ok, _} = Rooms.register(room)

    conn = call(Plug.Test.conn(:get, "/v1/dial?communities=harbour&clubs=chess"))
    assert conn.status == 200

    assert %{
             "dial" => %{"communities" => "harbour"},
             "rooms" => [%{"handle" => "alpha", "room" => "lobby", "scope" => scope}]
           } = JSON.decode!(conn.resp_body)

    assert scope == Junderground.Constructs.scope_id(dial)
  end
end
