defmodule Junderground.RoomsTest do
  use ExUnit.Case, async: false

  alias Junderground.{Admission, Directory, Keys, Record, Rentals, Rooms, ServerKey, Token, Turn}

  setup do
    dir = Path.join(System.tmp_dir!(), "jg-rooms-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Application.put_env(:junderground, :data_dir, dir)
    ServerKey.reset()

    start_supervised!({Admission, data_dir: dir})
    start_supervised!({Directory, data_dir: dir})
    start_supervised!({Junderground.Lexicon, data_dir: dir})
    start_supervised!({Junderground.Rentals, data_dir: dir})
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

  test "a room is found by its scope inside the dial", %{pub: pub, priv: priv} do
    scope = %{"communities" => "warwick", "events" => "rock_show", "teams" => "the_greatest_band"}

    assert {:ok, _} =
             Rooms.register(
               room(pub, priv, %{"policy" => "open", "advertised" => "yes", "constructs" => scope})
             )

    assert {:ok, heads} =
             Rooms.dial(%{
               "communities" => "warwick",
               "events" => "rock_show",
               "teams" => "the_greatest_band",
               "clubs" => "chess"
             })

    assert [head] = heads
    assert head["constructs"]["events"] == "rock_show"

    # a narrower dial does not reach a wider room
    assert {:ok, []} = Rooms.dial(%{"events" => "rock_show"})

    # a universal room matches any dial
    universal =
      Rooms.build("alpha", "hall", pub, 1, %{
        "policy" => "open",
        "advertised" => "yes",
        "constructs" => %{}
      })
      |> Keys.sign_record(priv)

    assert {:ok, _} = Rooms.register(universal)
    assert {:ok, heads} = Rooms.dial(%{"events" => "christmas"})
    assert Enum.map(heads, & &1["record"]["room"]) == ["hall"]
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

  test "a rented room is closed outside its window", %{pub: pub, priv: priv} do
    assert {:ok, _} = Rooms.register(room(pub, priv, %{"policy" => "open"}))
    house("beta")
    now = System.system_time(:second)

    future =
      Rentals.build("alpha", "lobby", pub, 1, now + 3600, now + 7200)
      |> Keys.sign_record(priv)

    assert {:ok, _} = Rentals.create(future)

    assert {:error, :not_open} =
             Rooms.grant("alpha", "lobby", %{handle: "beta"}, %{"caps" => ["join"]})

    assert {:ok, _} = Rooms.grant("alpha", "lobby", %{handle: "alpha"}, %{"caps" => ["join"]})

    active =
      Rentals.build("alpha", "lobby", pub, 2, now - 60, now + 600, %{"prev" => future["sig"]})
      |> Keys.sign_record(priv)

    assert {:ok, active_view} = Rentals.create(active)

    assert {:ok, pass} =
             Rooms.issue_ticket("alpha", "lobby", %{handle: "alpha"}, %{
               "role" => "resident",
               "sub" => "beta",
               "bind" => "subject"
             })

    assert {:ok, grant} =
             Rooms.grant("alpha", "lobby", %{handle: "beta"}, %{"ticket" => pass["ticket"]})

    assert grant["expires"] <= active_view["end"]
  end

  test "an event ticket ends with its rental window", %{pub: pub, priv: priv} do
    assert {:ok, _} = Rooms.register(room(pub, priv, %{"policy" => "ticket"}))
    house("beta")
    now = System.system_time(:second)

    rental =
      Rentals.build("alpha", "lobby", pub, 1, now - 60, now + 600, %{"label" => "Rock Show"})
      |> Keys.sign_record(priv)

    assert {:ok, rental_view} = Rentals.create(rental)

    assert {:ok, ticket} =
             Rooms.issue_ticket("alpha", "lobby", %{handle: "alpha"}, %{
               "sub" => "beta",
               "uses" => 1,
               "expires" => now + 86_400
             })

    assert ticket["expires"] <= rental_view["end"]
    assert ticket["rental"] == rental_view["id"]

    assert {:ok, grant} =
             Rooms.grant("alpha", "lobby", %{handle: "beta"}, %{"ticket" => ticket["ticket"]})

    assert grant["expires"] <= rental_view["end"]
  end

  test "a bearer ticket can be spent by anyone admitted", %{pub: pub, priv: priv} do
    assert {:ok, _} = Rooms.register(room(pub, priv, %{"policy" => "ticket"}))
    house("beta")
    house("gamma")

    assert {:ok, ticket} =
             Rooms.issue_ticket("alpha", "lobby", %{handle: "alpha"}, %{
               "bind" => "bearer",
               "uses" => 1
             })

    assert ticket["bind"] == "bearer"

    assert {:ok, _} =
             Rooms.grant("alpha", "lobby", %{handle: "gamma"}, %{"ticket" => ticket["ticket"]})

    assert {:error, :ticket_spent} =
             Rooms.grant("alpha", "lobby", %{handle: "beta"}, %{"ticket" => ticket["ticket"]})
  end

  test "a resident pass carries the band, with resident caps", %{pub: pub, priv: priv} do
    assert {:ok, _} = Rooms.register(room(pub, priv, %{"policy" => "ticket"}))
    house("beta")
    now = System.system_time(:second)

    rental =
      Rentals.build("alpha", "lobby", pub, 1, now - 60, now + 3_600, %{
        "guest_start" => now - 60,
        "guest_end" => now + 3_600,
        "citizen" => "alpha"
      })
      |> Keys.sign_record(priv)

    assert {:ok, _} = Rentals.create(rental)

    assert {:ok, pass} =
             Rooms.issue_ticket("alpha", "lobby", %{handle: "alpha"}, %{
               "role" => "resident",
               "sub" => "beta",
               "bind" => "subject"
             })

    assert pass["role"] == "resident"
    assert pass["expires"] <= now + 3_600

    assert {:ok, grant} =
             Rooms.grant("alpha", "lobby", %{handle: "beta"}, %{
               "caps" => ["join", "publish_audio", "publish_video"],
               "ticket" => pass["ticket"]
             })

    assert grant["role"] == "resident"
    assert "publish_video" in grant["caps"]
    refute "moderate" in grant["caps"]
  end

  test "a guest is only admitted inside the guest window", %{pub: pub, priv: priv} do
    assert {:ok, _} = Rooms.register(room(pub, priv, %{"policy" => "ticket"}))
    house("beta")
    now = System.system_time(:second)

    rental =
      Rentals.build("alpha", "lobby", pub, 1, now - 60, now + 7_200, %{
        "guest_start" => now + 3_600,
        "guest_end" => now + 7_200
      })
      |> Keys.sign_record(priv)

    assert {:ok, _} = Rentals.create(rental)

    assert {:ok, ticket} =
             Rooms.issue_ticket("alpha", "lobby", %{handle: "alpha"}, %{
               "sub" => "beta",
               "expires" => now + 7_200
             })

    assert {:error, :not_open} =
             Rooms.grant("alpha", "lobby", %{handle: "beta"}, %{"ticket" => ticket["ticket"]})
  end

  test "a ticket says what it can do and carries a warranty", %{pub: pub, priv: priv} do
    assert {:ok, _} = Rooms.register(room(pub, priv, %{"policy" => "ticket"}))
    house("beta")
    now = System.system_time(:second)

    assert {:ok, ticket} =
             Rooms.issue_ticket("alpha", "lobby", %{handle: "alpha"}, %{
               "sub" => "beta",
               "grants" => ["room:alpha/lobby", "store:the_greatest_band"],
               "warranty" => %{
                 "terms" => "refund if the show is cancelled",
                 "until" => now + 86_400,
                 "covers" => ["entry", "merch"]
               }
             })

    assert "store:the_greatest_band" in ticket["grants"]
    assert ticket["warranty"]["terms"] =~ "refund"
  end

  test "the last minute before a rental is closed to non-ticketed people", %{
    pub: pub,
    priv: priv
  } do
    assert {:ok, _} = Rooms.register(room(pub, priv, %{"policy" => "open"}))
    house("beta")
    now = System.system_time(:second)

    rental =
      Rentals.build("alpha", "lobby", pub, 1, now + 30, now + 3_600)
      |> Keys.sign_record(priv)

    assert {:ok, _} = Rentals.create(rental)

    assert {:error, :door_closed} =
             Rooms.grant("alpha", "lobby", %{handle: "beta"}, %{"caps" => ["join"]})

    # the owner and a resident pass still get in
    assert {:ok, _} = Rooms.grant("alpha", "lobby", %{handle: "alpha"}, %{"caps" => ["join"]})

    assert {:ok, pass} =
             Rooms.issue_ticket("alpha", "lobby", %{handle: "alpha"}, %{
               "role" => "resident",
               "sub" => "beta",
               "bind" => "subject"
             })

    assert {:ok, grant} =
             Rooms.grant("alpha", "lobby", %{handle: "beta"}, %{"ticket" => pass["ticket"]})

    assert grant["ticketed"] == true
  end

  test "an older non-ticketed grant dies when the doors close", %{pub: pub, priv: priv} do
    assert {:ok, _} = Rooms.register(room(pub, priv, %{"policy" => "open"}))
    house("beta")
    now = System.system_time(:second)

    assert {:ok, grant} =
             Rooms.grant("alpha", "lobby", %{handle: "beta"}, %{"caps" => ["join"]})

    assert {:ok, _} = Rooms.verify_grant(grant["grant"])

    rental =
      Rentals.build("alpha", "lobby", pub, 1, now + 30, now + 3_600)
      |> Keys.sign_record(priv)

    assert {:ok, _} = Rentals.create(rental)
    assert {:error, :door_closed} = Rooms.verify_grant(grant["grant"])
  end

  test "the same room is found from other languages", %{pub: pub, priv: priv} do
    assert {:ok, _} =
             Rooms.register(
               room(pub, priv, %{
                 "policy" => "open",
                 "advertised" => "yes",
                 "constructs" => %{"events" => "christmas"}
               })
             )

    for word <- ["christmas", "圣诞节", "navidad", "weihnachten", "Χριστούγεννα"] do
      assert {:ok, [head]} = Rooms.dial(%{"events" => word})
      assert head["constructs"]["events"] == "christmas"
    end
  end

  test "a room may add its own alias", %{pub: pub, priv: priv} do
    assert {:ok, _} =
             Rooms.register(
               room(pub, priv, %{
                 "policy" => "open",
                 "advertised" => "yes",
                 "constructs" => %{"events" => "rock_show"},
                 "aliases" => %{"events" => ["le_spectacle"]}
               })
             )

    assert {:ok, [head]} = Rooms.dial(%{"events" => "le_spectacle"})
    assert head["constructs"]["events"] == "rock_show"
  end
end
