defmodule Junderground.RoomsTest do
  use ExUnit.Case, async: false

  alias Junderground.{Admission, Directory, Keys, Record, Rooms, ServerKey, Token, Turn}

  setup do
    dir = Path.join(System.tmp_dir!(), "jg-rooms-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Application.put_env(:junderground, :data_dir, dir)
    ServerKey.reset()

    start_supervised!({Admission, data_dir: dir})
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
    {:ok, _} = Admission.decide("alpha", "approved", "test", "", 0)

    %{pub: pub, priv: priv}
  end

  defp room(pub, priv, fields) do
    Rooms.build("alpha", "lobby", pub, 1, fields) |> Keys.sign_record(priv)
  end

  defp house(name) do
    {pub, priv} = Keys.generate()
    record = Record.build("register", name, pub, 1, %{}) |> Keys.sign_record(priv)
    {:ok, _} = Directory.register(record)
    {:ok, _} = Admission.decide(name, "approved", "test", "", 0)
    {pub, priv}
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

    house("beta")

    assert {:ok, grant} =
             Rooms.grant("alpha", "lobby", %{handle: "beta"}, %{"caps" => ["join", "record"]})

    assert grant["caps"] == ["join"]

    assert {:ok, owner} =
             Rooms.grant("alpha", "lobby", %{handle: "alpha"}, %{"caps" => ["join", "record"]})

    assert "record" in owner["caps"]
  end

  test "an invite room needs an invite grant", %{pub: pub, priv: priv} do
    assert {:ok, _} = Rooms.register(room(pub, priv, %{"policy" => "invite"}))
    house("beta")

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

  test "a room is found by the dial tuple the Mail app uses", %{pub: pub, priv: priv} do
    dial = %{"communities" => "harbour", "clubs" => "chess", "projects" => "radio"}

    assert {:ok, _} =
             Rooms.register(
               room(pub, priv, %{"policy" => "open", "advertised" => "yes", "constructs" => dial})
             )

    assert {:ok, heads} = Rooms.by_channel(Junderground.Constructs.channel_id(dial))
    assert [head] = heads
    assert head["constructs"]["communities"] == "harbour"
    assert head["advertised"] == true

    # a different dial names a different room
    assert {:ok, []} =
             Rooms.by_channel(Junderground.Constructs.channel_id(%{"communities" => "elsewhere"}))
  end

  test "a ticket is bound to one person and is spent", %{pub: pub, priv: priv} do
    assert {:ok, _} = Rooms.register(room(pub, priv, %{"policy" => "ticket"}))
    house("beta")

    assert {:ok, ticket} =
             Rooms.issue_ticket("alpha", "lobby", %{handle: "alpha"}, %{
               "sub" => "beta",
               "uses" => 1,
               "caps" => ["join", "publish_audio"]
             })

    # the owner cannot spend a ticket minted for someone else
    assert {:error, :forbidden} =
             Rooms.grant("alpha", "lobby", %{handle: "alpha"}, %{"ticket" => ticket["ticket"]})

    assert {:ok, grant} =
             Rooms.grant("alpha", "lobby", %{handle: "beta"}, %{"ticket" => ticket["ticket"]})

    assert "join" in grant["caps"]

    assert {:error, :ticket_spent} =
             Rooms.grant("alpha", "lobby", %{handle: "beta"}, %{"ticket" => ticket["ticket"]})
  end

  test "a direct room is only its members", %{pub: pub, priv: priv} do
    assert {:ok, _} =
             Rooms.register(room(pub, priv, %{"policy" => "direct", "members" => ["beta"]}))

    house("beta")
    house("gamma")

    assert {:ok, _} = Rooms.grant("alpha", "lobby", %{handle: "beta"}, %{"caps" => ["join"]})
    assert {:ok, _} = Rooms.grant("alpha", "lobby", %{handle: "alpha"}, %{"caps" => ["join"]})

    assert {:error, :forbidden} =
             Rooms.grant("alpha", "lobby", %{handle: "gamma"}, %{"caps" => ["join"]})
  end

  test "a suspension kills grants already issued", %{pub: pub, priv: priv} do
    assert {:ok, _} = Rooms.register(room(pub, priv, %{"policy" => "open"}))

    assert {:ok, grant} =
             Rooms.grant("alpha", "lobby", %{handle: "alpha"}, %{"caps" => ["join"]})

    assert {:ok, _} = Rooms.verify_grant(grant["grant"])

    assert {:ok, _} = Admission.decide("alpha", "suspended", "test", "abuse", 0)
    assert {:error, :revoked} = Rooms.verify_grant(grant["grant"])

    assert {:ok, _} = Admission.decide("alpha", "approved", "test", "cleared", 0)

    assert {:ok, fresh} =
             Rooms.grant("alpha", "lobby", %{handle: "alpha"}, %{"caps" => ["join"]})

    assert {:ok, _} = Rooms.verify_grant(fresh["grant"])
  end
end
