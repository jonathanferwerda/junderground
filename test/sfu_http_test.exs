defmodule Junderground.SfuHttpTest do
  use ExUnit.Case, async: false

  alias Junderground.{
    Admission,
    Auth,
    Directory,
    Keys,
    Nonces,
    Record,
    Rooms,
    Router,
    ServerKey,
    Signaling
  }

  alias Junderground.Sfu
  alias Junderground.Sfu.{Health, Local}

  @secret "0123456789abcdef0123456789abcdef"
  @env_keys [:sfu_url, :sfu_key, :sfu_secret, :sfu_threshold, :sfu_token_ttl, :sfu_transport]

  setup do
    previous = Enum.map(@env_keys, &{&1, Application.get_env(:junderground, &1)})

    dir = Path.join(System.tmp_dir!(), "jg-sfu-http-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Application.put_env(:junderground, :data_dir, dir)
    Application.put_env(:junderground, :turn_urls, [])
    Application.put_env(:junderground, :turn_secret, nil)
    :persistent_term.erase(:jg_sfu_probe_down)
    ServerKey.reset()

    start_supervised!(Nonces)
    start_supervised!({Admission, data_dir: dir})
    start_supervised!({Directory, data_dir: dir})
    start_supervised!({Junderground.Lexicon, data_dir: dir})
    start_supervised!({Junderground.Rentals, data_dir: dir})
    start_supervised!({Rooms, data_dir: dir})
    start_supervised!({Local, data_dir: dir})
    start_supervised!(Signaling)

    {pub, priv} = Keys.generate()

    house =
      Record.build("register", "alpha", pub, 1, %{"name" => "Alpha"})
      |> Keys.sign_record(priv)

    {:ok, _} = Directory.register(house)
    {:ok, _} = Admission.decide("alpha", "approved", "test", "", 0)

    room =
      Rooms.build("alpha", "lobby", pub, 1, %{"policy" => "open", "max" => 16})
      |> Keys.sign_record(priv)

    {:ok, _} = Rooms.register(room)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:junderground, key)
        {key, value} -> Application.put_env(:junderground, key, value)
      end)

      Application.put_env(:junderground, :data_dir, "tmp/test-data")
      :persistent_term.erase(:jg_sfu_probe_down)
      ServerKey.reset()
      File.rm_rf(dir)
    end)

    %{pub: pub, priv: priv}
  end

  defp call(conn), do: Router.call(conn, [])

  defp signed(conn, body, handle, priv) do
    timestamp = Integer.to_string(System.system_time(:second))
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

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

  defp configure_sfu do
    Application.put_env(:junderground, :sfu_url, "wss://sfu.test/sfu")
    Application.put_env(:junderground, :sfu_key, "lk_test")
    Application.put_env(:junderground, :sfu_secret, @secret)
    Application.put_env(:junderground, :sfu_threshold, 5)
    Application.put_env(:junderground, :sfu_token_ttl, 300)
  end

  defp start_health do
    start_supervised!({Health, probe: &health_probe/0})
    assert :ok = Health.probe_now()
  end

  defp health_probe do
    if :persistent_term.get(:jg_sfu_probe_down, false), do: {:error, :down}, else: :ok
  end

  defp grant(caps \\ ["join", "publish_audio", "publish_video", "subscribe"]) do
    {:ok, grant} = Rooms.grant("alpha", "lobby", %{handle: "alpha"}, %{"caps" => caps})
    grant
  end

  defp occupy(n) do
    for i <- 1..n do
      {:ok, _} = Signaling.join("alpha/lobby", %{jti: "socket#{i}", subject: "beta"})
    end
  end

  defp sfu_token(grant, handle, priv) do
    body = JSON.encode!(%{"grant" => grant["grant"]})

    Plug.Test.conn(:post, "/v1/rooms/alpha/lobby/sfu/token", body)
    |> signed(body, handle, priv)
    |> call()
  end

  defp other_house(name) do
    {pub, priv} = Keys.generate()
    record = Record.build("register", name, pub, 1, %{}) |> Keys.sign_record(priv)
    {:ok, _} = Directory.register(record)
    {:ok, _} = Admission.decide(name, "approved", "test", "", 0)
    {pub, priv}
  end

  test "a signed request at the threshold mints a LiveKit join token", %{priv: priv} do
    configure_sfu()
    start_health()
    grant = grant()
    occupy(5)

    conn = sfu_token(grant, "alpha", priv)
    assert conn.status == 200

    response = JSON.decode!(conn.resp_body)
    assert response["mode"] == "sfu"
    assert response["url"] == "wss://sfu.test/sfu"
    assert response["room"] =~ ~r/^r_[A-Za-z0-9_-]{16}$/
    assert response["peers"] == 5
    assert response["ice_servers"] == []
    assert response["expires"] > System.system_time(:second)

    [header, payload, signature] = String.split(response["token"], ".")
    assert JSON.decode!(Base.url_decode64!(header, padding: false))["alg"] == "HS256"
    signature = Base.url_decode64!(signature, padding: false)
    assert signature == :crypto.mac(:hmac, :sha256, @secret, header <> "." <> payload)

    claims = JSON.decode!(Base.url_decode64!(payload, padding: false))
    assert claims["iss"] == "lk_test"
    assert claims["video"]["room"] == response["room"]
    assert claims["video"]["roomJoin"] == true
    assert claims["video"]["roomCreate"] == false
    assert claims["video"]["canPublishData"] == false

    {:ok, verified} = Rooms.verify_grant(grant["grant"])
    assert claims["sub"] == verified["jti"]

    assert Enum.any?(Local.grants(), &(&1["jti"] == verified["jti"]))
    assert Local.room_for(response["room"]) == "alpha/lobby"
  end

  test "a house cannot mint a token for another house's grant" do
    configure_sfu()
    start_health()
    grant = grant()
    {_pub, beta_priv} = other_house("beta")

    conn = sfu_token(grant, "beta", beta_priv)
    assert conn.status == 403
    assert JSON.decode!(conn.resp_body)["error"]["code"] == "forbidden"
  end

  test "a revoked grant cannot mint an SFU token", %{priv: priv} do
    configure_sfu()
    start_health()
    grant = grant()
    {:ok, payload} = Rooms.verify_grant(grant["grant"])

    assert :ok = Rooms.revoke("alpha", "lobby", %{handle: "alpha"}, payload["jti"], nil)

    conn = sfu_token(grant, "alpha", priv)
    assert conn.status == 409
    assert JSON.decode!(conn.resp_body)["error"]["code"] == "revoked"
  end

  test "a full room refuses the token before it chooses a mode", %{pub: pub, priv: priv} do
    configure_sfu()
    start_health()

    {:ok, head} = Rooms.latest("alpha", "lobby")

    update =
      Rooms.build("alpha", "lobby", pub, 2, %{
        "kind" => "update",
        "prev" => head["sig"],
        "policy" => "open",
        "max" => 2
      })
      |> Keys.sign_record(priv)

    assert {:ok, _} = Rooms.register(update)

    grant = grant()
    occupy(2)

    conn = sfu_token(grant, "alpha", priv)
    assert conn.status == 409
    assert JSON.decode!(conn.resp_body)["error"]["code"] == "room_full"
  end

  test "a threshold-sized room with no SFU answers 503, not a bad mesh", %{priv: priv} do
    Application.put_env(:junderground, :sfu_url, nil)
    Application.put_env(:junderground, :sfu_key, nil)
    Application.put_env(:junderground, :sfu_secret, nil)

    grant = grant()
    occupy(5)

    conn = sfu_token(grant, "alpha", priv)
    assert conn.status == 503
    assert Plug.Conn.get_resp_header(conn, "retry-after") == ["30"]
    assert JSON.decode!(conn.resp_body)["error"]["code"] == "sfu_unavailable"
  end

  test "below the threshold the answer is mesh, and the grant says so", %{priv: priv} do
    Application.put_env(:junderground, :sfu_url, nil)
    Application.put_env(:junderground, :sfu_key, nil)
    Application.put_env(:junderground, :sfu_secret, nil)

    body = JSON.encode!(%{"caps" => ["join", "publish_audio", "subscribe"]})

    grant_conn =
      Plug.Test.conn(:post, "/v1/rooms/alpha/lobby/token", body)
      |> signed(body, "alpha", priv)
      |> call()

    assert grant_conn.status == 200
    grant = JSON.decode!(grant_conn.resp_body)
    assert grant["media"] == %{"mode" => "mesh", "reason" => "below_threshold"}

    occupy(4)

    conn = sfu_token(grant, "alpha", priv)
    assert conn.status == 200

    response = JSON.decode!(conn.resp_body)
    assert response["mode"] == "mesh"
    assert response["room"] == "alpha/lobby"
    assert response["peers"] == 4
    assert response["ice_servers"] == []
    assert response["media"] == %{"mode" => "mesh", "reason" => "below_threshold"}
  end

  test "meta advertises the SFU only while the health cache says it is up" do
    configure_sfu()
    start_health()

    conn = call(Plug.Test.conn(:get, "/v1/meta"))
    assert conn.status == 200
    meta = JSON.decode!(conn.resp_body)

    assert meta["sfu"] == %{
             "available" => true,
             "adapter" => "livekit",
             "url" => "wss://sfu.test/sfu",
             "threshold" => 5,
             "token_ttl" => 300
           }

    assert "sfu" in meta["features"]

    :persistent_term.put(:jg_sfu_probe_down, true)
    for _ <- 1..3, do: assert({:error, :down} = Health.probe_now())

    assert Health.status().up == false

    meta = call(Plug.Test.conn(:get, "/v1/meta")) |> Map.get(:resp_body) |> JSON.decode!()
    assert meta["sfu"]["available"] == false
    refute "sfu" in meta["features"]
  end

  test "the owner can revoke a grant and the SFU participant is removed best effort", %{
    priv: priv
  } do
    configure_sfu()
    start_health()
    grant = grant()
    {:ok, payload} = Rooms.verify_grant(grant["grant"])

    test_pid = self()

    Application.put_env(:junderground, :sfu_transport, fn url, headers, body ->
      send(test_pid, {:twirp, url, headers, body})
      {:ok, 200, "{}"}
    end)

    body = JSON.encode!(%{"jti" => payload["jti"]})

    conn =
      Plug.Test.conn(:post, "/v1/rooms/alpha/lobby/sfu/revoke", body)
      |> signed(body, "alpha", priv)
      |> call()

    assert conn.status == 200

    assert JSON.decode!(conn.resp_body) == %{
             "ok" => true,
             "jti" => payload["jti"],
             "removed" => true
           }

    assert_received {:twirp, url, headers, request_body}
    assert url == "https://sfu.test/sfu/twirp/livekit.RoomService/RemoveParticipant"
    assert {"authorization", "Bearer " <> _jwt} = List.keyfind(headers, "authorization", 0)
    assert %{"room" => opaque, "identity" => jti} = JSON.decode!(request_body)
    assert opaque == Sfu.opaque_room(payload["room_key"])
    assert jti == payload["jti"]

    assert {:error, :revoked} = Rooms.verify_grant(grant["grant"])
  end

  test "revoke is owner-only" do
    configure_sfu()
    start_health()
    grant = grant()
    {:ok, payload} = Rooms.verify_grant(grant["grant"])
    {_pub, beta_priv} = other_house("beta")

    body = JSON.encode!(%{"jti" => payload["jti"]})

    conn =
      Plug.Test.conn(:post, "/v1/rooms/alpha/lobby/sfu/revoke", body)
      |> signed(body, "beta", beta_priv)
      |> call()

    assert conn.status == 403
    assert {:ok, _} = Rooms.verify_grant(grant["grant"])
  end
end
