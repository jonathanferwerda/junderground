defmodule Junderground.RoomsTest do
  use ExUnit.Case, async: false

  alias Junderground.{Directory, Keys, Record, Rooms, ServerKey, Token, Turn}

  setup do
    dir = Path.join(System.tmp_dir!(), "jg-rooms-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Application.put_env(:junderground, :data_dir, dir)
    ServerKey.reset()

    start_supervised!({Directory, data_dir: dir})
    start_supervised!({Rooms, data_dir: dir})

    on_exit(fn ->
      Application.put_env(:junderground, :data_dir, "tmp/test-data")
      Application.put_env(:junderground, :turn_urls, [])
      Application.put_env(:junderground, :turn_secret, nil)
      ServerKey.reset()
      File.rm_rf(dir)
    end)

    {pub, priv} = Keys.generate()

    house =
      Record.build("register", "alpha", pub, 1, %{"name" => "Alpha"}) |> Keys.sign_record(priv)

    {:ok, _} = Directory.register(house)

    %{pub: pub, priv: priv}
  end

  defp room(pub, priv, fields) do
    Rooms.build("alpha", "lobby", pub, 1, fields) |> Keys.sign_record(priv)
  end

  test "the owner gets a grant with the owner capabilities", %{pub: pub, priv: priv} do
    assert {:ok, _} = Rooms.register(room(pub, priv, %{"policy" => "open"}))

    assert {:ok, grant} =
             Rooms.grant("alpha", "lobby", %{handle: "alpha"}, %{
               "caps" => ["join", "publish_audio"]
             })

    assert grant["caps"] == ["join", "publish_audio"]
    assert grant["expires"] > System.system_time(:second)

    assert {:ok, payload} = Token.verify(grant["grant"], ServerKey.public_b64())
    assert payload["room"] == "alpha/lobby"
    assert payload["sub"] == "alpha"
    assert payload["room_key"] =~ ~r/^[0-9a-f]{64}$/
    assert {:ok, _} = Rooms.verify_grant(grant["grant"])
  end

  test "an open room admits another house; recording stays with the owner", %{
    pub: pub,
    priv: priv
  } do
    assert {:ok, _} =
             Rooms.register(room(pub, priv, %{"policy" => "open", "recording" => "allow"}))

    assert {:ok, grant} =
             Rooms.grant("alpha", "lobby", %{handle: "beta"}, %{"caps" => ["join", "record"]})

    assert grant["caps"] == ["join"]

    assert {:ok, owner} =
             Rooms.grant("alpha", "lobby", %{handle: "alpha"}, %{"caps" => ["join", "record"]})

    assert "record" in owner["caps"]
  end

  test "an invite room needs an invite grant", %{pub: pub, priv: priv} do
    assert {:ok, _} = Rooms.register(room(pub, priv, %{"policy" => "invite"}))

    assert {:error, :invite_required} =
             Rooms.grant("alpha", "lobby", %{handle: "beta"}, %{"caps" => ["join"]})

    assert {:ok, invite} =
             Rooms.grant("alpha", "lobby", %{handle: "alpha"}, %{"caps" => ["join", "invite"]})

    assert {:ok, grant} =
             Rooms.grant("alpha", "lobby", %{handle: "beta"}, %{
               "caps" => ["join"],
               "invite" => invite["grant"]
             })

    assert "join" in grant["caps"]
  end

  test "a revoked grant stops verifying", %{pub: pub, priv: priv} do
    assert {:ok, _} = Rooms.register(room(pub, priv, %{"policy" => "open"}))

    assert {:ok, grant} =
             Rooms.grant("alpha", "lobby", %{handle: "alpha"}, %{"caps" => ["join"]})

    assert {:ok, payload} = Token.verify(grant["grant"], ServerKey.public_b64())

    assert :ok =
             Rooms.revoke("alpha", "lobby", %{handle: "alpha"}, payload["jti"], payload["exp"])

    assert {:error, :revoked} = Rooms.verify_grant(grant["grant"])
  end

  test "an expired grant is refused", %{pub: pub, priv: priv} do
    payload = %{
      "format" => "junderground-grant",
      "version" => 1,
      "iss" => "http://localhost:4100",
      "room" => "alpha/lobby",
      "room_key" => "x",
      "sub" => "alpha",
      "caps" => ["join"],
      "iat" => System.system_time(:second) - 100,
      "exp" => System.system_time(:second) - 10,
      "jti" => "expired-token"
    }

    token = Token.mint(payload, ServerKey.private())
    assert {:error, :expired} = Rooms.verify_grant(token)
  end

  test "TURN credentials are coturn-shaped and time-limited" do
    Application.put_env(:junderground, :turn_urls, ["turn:turn.example:3478"])
    Application.put_env(:junderground, :turn_secret, "0123456789abcdef0123456789abcdef")

    assert [server] = Turn.credentials("alpha", 600)
    assert server["urls"] == ["turn:turn.example:3478"]
    assert server["username"] =~ ~r/^\d+:alpha$/

    expected =
      :crypto.mac(:hmac, :sha, "0123456789abcdef0123456789abcdef", server["username"])
      |> Base.encode64()

    assert server["credential"] == expected
  end
end
