# tests-for: lib/junderground/sfu.ex lib/junderground/sfu/token.ex lib/junderground/sfu/health.ex lib/junderground/sfu/local.ex lib/junderground/sfu/client.ex lib/junderground/sfu/reconciler.ex
defmodule Junderground.SfuTest do
  use ExUnit.Case, async: false

  alias Junderground.{Admission, Directory, Keys, Record, Rooms, ServerKey}
  alias Junderground.Sfu
  alias Junderground.Sfu.{Local, Reconciler, Token}

  @secret "0123456789abcdef0123456789abcdef"
  @env_keys [:sfu_url, :sfu_key, :sfu_secret, :sfu_threshold, :sfu_token_ttl, :sfu_transport]

  setup do
    previous = Enum.map(@env_keys, &{&1, Application.get_env(:junderground, &1)})

    dir = Path.join(System.tmp_dir!(), "jg-sfu-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Application.put_env(:junderground, :data_dir, dir)
    ServerKey.reset()

    start_supervised!({Admission, data_dir: dir})
    start_supervised!({Directory, data_dir: dir})
    start_supervised!({Junderground.Lexicon, data_dir: dir})
    start_supervised!({Junderground.Rentals, data_dir: dir})
    start_supervised!({Rooms, data_dir: dir})
    start_supervised!({Local, data_dir: dir})

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

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:junderground, key)
        {key, value} -> Application.put_env(:junderground, key, value)
      end)

      Application.put_env(:junderground, :data_dir, "tmp/test-data")
      ServerKey.reset()
      File.rm_rf(dir)
    end)

    %{pub: pub, priv: priv, dir: dir}
  end

  defp configure_sfu do
    Application.put_env(:junderground, :sfu_url, "wss://sfu.example/sfu")
    Application.put_env(:junderground, :sfu_key, "lk_test")
    Application.put_env(:junderground, :sfu_secret, @secret)
    Application.put_env(:junderground, :sfu_threshold, 5)
    Application.put_env(:junderground, :sfu_token_ttl, 300)
  end

  defp grant(map) do
    Map.merge(
      %{
        "jti" => "grant0123456789",
        "room" => "alpha/lobby",
        "room_key" => String.duplicate("a", 64),
        "sub" => "alpha",
        "role" => "citizen",
        "caps" => ["join", "publish_audio", "publish_video", "subscribe"],
        "epoch" => 0,
        "exp" => System.system_time(:second) + 900
      },
      map
    )
  end

  defp decode_jwt(jwt) do
    [header64, payload64, signature64] = String.split(jwt, ".")
    header = JSON.decode!(Base.url_decode64!(header64, padding: false))
    claims = JSON.decode!(Base.url_decode64!(payload64, padding: false))
    signature = Base.url_decode64!(signature64, padding: false)
    {header, claims, header64 <> "." <> payload64, signature}
  end

  test "the threshold is the live count, bounded by the room max" do
    Application.put_env(:junderground, :sfu_threshold, 5)

    assert Sfu.mode(%{"max" => 16}, 4) == "mesh"
    assert Sfu.mode(%{"max" => 16}, 5) == "sfu"
    assert Sfu.mode(%{"max" => 16}, 9) == "sfu"

    # a small room never becomes SFU
    assert Sfu.mode(%{"max" => 4}, 10) == "mesh"

    # without a room record the threshold alone decides
    assert Sfu.mode("alpha/lobby", 5) == "sfu"
    assert Sfu.mode("alpha/lobby", 4) == "mesh"

    Application.put_env(:junderground, :sfu_threshold, 3)
    assert Sfu.mode(%{"max" => 16}, 3) == "sfu"
    assert Sfu.mode(%{"max" => 16}, 2) == "mesh"
  end

  test "the opaque room is stable, per-room, and not the raw key's hash" do
    Application.put_env(:junderground, :sfu_secret, @secret)

    key = String.duplicate("a", 64)
    opaque = Sfu.opaque_room(key)

    assert String.starts_with?(opaque, "r_")
    assert String.length(opaque) == 18
    assert opaque == Sfu.opaque_room(key)
    assert opaque != Sfu.opaque_room(String.duplicate("b", 64))
    refute String.contains?(opaque, "alpha")

    plain =
      "r_" <>
        (:crypto.hash(:sha256, key)
         |> Base.url_encode64(padding: false)
         |> String.slice(0, 16))

    assert opaque != plain

    Application.put_env(:junderground, :sfu_secret, String.duplicate("f", 32))
    assert Sfu.opaque_room(key) != opaque
  end

  test "a join JWT carries the design's claims and an independent HMAC" do
    configure_sfu()
    now = 1_760_000_000
    grant = grant(%{"exp" => now + 3_600})

    assert {:ok, minted} = Token.mint(grant, now: now, ttl: 300)

    {header, claims, signed, signature} = decode_jwt(minted.token)

    assert header == %{"alg" => "HS256", "typ" => "JWT"}
    assert signature == :crypto.mac(:hmac, :sha256, @secret, signed)

    assert claims["iss"] == "lk_test"
    assert claims["sub"] == grant["jti"]
    assert claims["nbf"] == now
    assert claims["exp"] == now + 300
    assert minted.expires == now + 300

    assert claims["video"] == %{
             "room" => Sfu.opaque_room(grant["room_key"]),
             "roomJoin" => true,
             "roomCreate" => false,
             "roomRecord" => false,
             "canPublish" => true,
             "canSubscribe" => true,
             "canPublishData" => false,
             "roomAdmin" => true
           }

    assert minted.room == Sfu.opaque_room(grant["room_key"])
  end

  test "the role maps publish and admin; a guest needs publish_video for a camera" do
    configure_sfu()
    now = System.system_time(:second)

    resident = grant(%{"role" => "resident", "exp" => now + 900})
    assert {:ok, minted} = Token.mint(resident, now: now)
    {_h, claims, _signed, _sig} = decode_jwt(minted.token)
    assert claims["video"]["roomAdmin"] == false
    assert claims["video"]["canPublish"] == true
    assert claims["video"]["canSubscribe"] == true
    refute Map.has_key?(claims["video"], "canPublishSources")

    guest =
      grant(%{
        "role" => "guest",
        "caps" => ["join", "publish_audio", "subscribe"],
        "exp" => now + 900
      })

    assert {:ok, minted} = Token.mint(guest, now: now)
    {_h, claims, _signed, _sig} = decode_jwt(minted.token)
    assert claims["video"]["roomAdmin"] == false
    assert claims["video"]["canPublish"] == true
    assert claims["video"]["canPublishSources"] == ["microphone"]

    guest_video = put_in(guest, ["caps"], ["join", "publish_audio", "publish_video", "subscribe"])
    assert {:ok, minted} = Token.mint(guest_video, now: now)
    {_h, claims, _signed, _sig} = decode_jwt(minted.token)
    assert claims["video"]["canPublishSources"] == ["microphone", "camera"]

    # a grant without a publish capability cannot publish, whatever its role
    viewer = grant(%{"role" => "citizen", "caps" => ["join", "subscribe"], "exp" => now + 900})
    assert {:ok, minted} = Token.mint(viewer, now: now)
    {_h, claims, _signed, _sig} = decode_jwt(minted.token)
    assert claims["video"]["canPublish"] == false
    assert claims["video"]["roomAdmin"] == true
  end

  test "the JWT never outlives the grant's own expiry" do
    configure_sfu()
    now = 1_760_000_000

    short = grant(%{"exp" => now + 60})
    assert {:ok, minted} = Token.mint(short, now: now, ttl: 300)
    assert minted.expires == now + 60

    long = grant(%{"exp" => now + 3_600})
    assert {:ok, minted} = Token.mint(long, now: now, ttl: 300)
    assert minted.expires == now + 300

    expired = grant(%{"exp" => now - 1})
    assert {:error, :expired} = Token.mint(expired, now: now)
  end

  test "media reasons follow configuration and health" do
    Application.put_env(:junderground, :sfu_url, nil)
    Application.put_env(:junderground, :sfu_key, nil)
    Application.put_env(:junderground, :sfu_secret, nil)
    Application.put_env(:junderground, :sfu_threshold, 5)

    assert Sfu.media(%{"max" => 16}, 5) == %{
             "mode" => "mesh",
             "reason" => "sfu_unconfigured"
           }

    assert Sfu.media(%{"max" => 16}, 4) == %{
             "mode" => "mesh",
             "reason" => "below_threshold"
           }

    assert Sfu.media(%{"max" => 4}, 20) == %{"mode" => "mesh", "reason" => "room_max"}

    configure_sfu()

    # configured but no health process: never pretend it is up
    assert Sfu.media(%{"max" => 16}, 5) == %{
             "mode" => "mesh",
             "reason" => "sfu_unavailable"
           }
  end

  test "the local map records a grant and the reconciler removes failures" do
    configure_sfu()

    {:ok, grant} =
      Rooms.grant("alpha", "lobby", %{handle: "alpha"}, %{
        "caps" => ["join", "publish_audio", "subscribe"]
      })

    {:ok, payload} = Rooms.verify_grant(grant["grant"])
    opaque = Sfu.opaque_room(payload["room_key"])

    entry =
      Map.put(
        Map.take(payload, ["jti", "room", "room_key", "exp", "epoch", "role", "caps", "sub"]),
        "opaque",
        opaque
      )

    assert :ok = Local.remember(entry)
    assert Local.room_for(opaque) == "alpha/lobby"
    assert Enum.any?(Local.grants(), &(&1["jti"] == payload["jti"]))

    jti = payload["jti"]
    test_pid = self()
    list = fn ^opaque -> {:ok, [jti, "intruder"]} end
    remove = fn ^opaque, identity -> send(test_pid, {:removed, identity}) end

    assert :ok = Reconciler.sweep(list: list, remove: remove)
    assert_received {:removed, "intruder"}
    refute_received {:removed, ^jti}

    assert :ok = Rooms.revoke("alpha", "lobby", %{handle: "alpha"}, payload["jti"], nil)
    assert :ok = Reconciler.sweep(list: list, remove: remove)
    assert_received {:removed, ^jti}
  end

  test "a suspension's epoch bump removes the participant on the next sweep" do
    configure_sfu()

    {:ok, grant} =
      Rooms.grant("alpha", "lobby", %{handle: "alpha"}, %{"caps" => ["join"]})

    {:ok, payload} = Rooms.verify_grant(grant["grant"])
    opaque = Sfu.opaque_room(payload["room_key"])

    entry =
      Map.put(
        Map.take(payload, ["jti", "room", "room_key", "exp", "epoch", "role", "caps", "sub"]),
        "opaque",
        opaque
      )

    assert :ok = Local.remember(entry)

    assert {:ok, _} = Admission.decide("alpha", "suspended", "test", "", 0)

    jti = payload["jti"]
    test_pid = self()
    list = fn ^opaque -> {:ok, [jti]} end
    remove = fn ^opaque, identity -> send(test_pid, {:removed, identity}) end

    assert :ok = Reconciler.sweep(list: list, remove: remove)
    assert_received {:removed, ^jti}
  end

  test "expired rows are cleaned, including their opaque room map" do
    configure_sfu()

    expired =
      grant(%{"exp" => System.system_time(:second) - 10, "room_key" => String.duplicate("c", 64)})

    entry = Map.put(expired, "opaque", Sfu.opaque_room(expired["room_key"]))

    assert :ok = Local.remember(entry)
    assert Local.grants() == []
    assert Local.rooms() == []
  end

  test "the reconciler process survives :sweep and calls the room service" do
    configure_sfu()

    row = grant(%{"room_key" => String.duplicate("d", 64)})
    opaque = Sfu.opaque_room(row["room_key"])
    assert :ok = Local.remember(Map.put(row, "opaque", opaque))

    test_pid = self()

    Application.put_env(:junderground, :sfu_transport, fn url, _headers, _body ->
      send(test_pid, {:twirp, url})

      if String.ends_with?(url, "ListParticipants") do
        {:ok, 200, JSON.encode!(%{"participants" => [%{"identity" => "intruder"}]})}
      else
        {:ok, 200, "{}"}
      end
    end)

    start_supervised!({Reconciler, interval: 3_600_000})
    reconciler = Process.whereis(Reconciler)

    send(reconciler, :sweep)
    _state = :sys.get_state(reconciler)

    assert Process.alive?(reconciler)

    assert_received {:twirp, "https://sfu.example/sfu/twirp/livekit.RoomService/ListParticipants"}

    assert_received {:twirp,
                     "https://sfu.example/sfu/twirp/livekit.RoomService/RemoveParticipant"}
  end
end
