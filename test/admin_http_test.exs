defmodule Junderground.AdminHttpTest do
  use ExUnit.Case, async: false

  alias Junderground.{
    Admin,
    Admission,
    Auth,
    Directory,
    Keys,
    Nonces,
    Record,
    Rooms,
    Router,
    ServerKey
  }

  setup do
    dir = Path.join(System.tmp_dir!(), "jg-admin-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Application.put_env(:junderground, :data_dir, dir)
    ServerKey.reset()

    {admin_pub, admin_priv} = Keys.generate()
    Application.put_env(:junderground, :admin_keys, [admin_pub])

    start_supervised!(Nonces)
    start_supervised!({Admission, data_dir: dir})
    start_supervised!({Directory, data_dir: dir})
    start_supervised!({Junderground.Rentals, data_dir: dir})
    start_supervised!({Rooms, data_dir: dir})

    on_exit(fn ->
      Application.put_env(:junderground, :data_dir, "tmp/test-data")
      Application.put_env(:junderground, :admin_keys, [])
      ServerKey.reset()
      File.rm_rf(dir)
    end)

    %{admin_pub: admin_pub, admin_priv: admin_priv}
  end

  defp call(conn), do: Router.call(conn, [])

  defp signature(conn, body, timestamp, nonce, priv) do
    Auth.message(conn, body, timestamp, nonce)
    |> then(&:crypto.sign(:eddsa, :none, &1, [priv, :ed25519]))
    |> Base.encode64()
  end

  defp signed(conn, body, handle, priv) do
    timestamp = Integer.to_string(System.system_time(:second))
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    sig = signature(conn, body, timestamp, nonce, priv)

    conn
    |> Plug.Conn.put_req_header("x-jg-handle", handle)
    |> Plug.Conn.put_req_header("x-jg-timestamp", timestamp)
    |> Plug.Conn.put_req_header("x-jg-nonce", nonce)
    |> Plug.Conn.put_req_header("x-jg-signature", sig)
  end

  defp admin_signed(conn, body, pub, priv) do
    timestamp = Integer.to_string(System.system_time(:second))
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    sig = signature(conn, body, timestamp, nonce, priv)

    conn
    |> Plug.Conn.put_req_header("x-jg-admin", pub)
    |> Plug.Conn.put_req_header("x-jg-timestamp", timestamp)
    |> Plug.Conn.put_req_header("x-jg-nonce", nonce)
    |> Plug.Conn.put_req_header("x-jg-signature", sig)
  end

  defp house(name) do
    {pub, priv} = Keys.generate()
    record = Record.build("register", name, pub, 1, %{"name" => name}) |> Keys.sign_record(priv)
    body = JSON.encode!(record)
    conn = call(Plug.Test.conn(:post, "/v1/houses", body))
    assert conn.status == 201
    {pub, priv}
  end

  defp decide(ctx, handle, status, reason \\ "checked") do
    body = JSON.encode!(%{"status" => status, "reason" => reason})

    conn =
      Plug.Test.conn(:post, "/v1/admin/houses/#{handle}/status", body)
      |> admin_signed(body, ctx.admin_pub, ctx.admin_priv)
      |> call()

    assert conn.status == 200
    JSON.decode!(conn.resp_body)
  end

  test "the queue shows a pending house and approval opens the door", ctx do
    {_pub, priv} = house("alpha")

    # a pending house cannot buy a grant
    body = JSON.encode!(%{"caps" => ["join"]})

    conn =
      Plug.Test.conn(:post, "/v1/rooms/alpha/lobby/token", body)
      |> signed(body, "alpha", priv)
      |> call()

    assert conn.status == 403

    queue =
      call(
        Plug.Test.conn(:get, "/v1/admin/queue")
        |> admin_signed("", ctx.admin_pub, ctx.admin_priv)
      )

    assert queue.status == 200
    assert %{"pending" => [%{"handle" => "alpha"}]} = JSON.decode!(queue.resp_body)

    assert %{"ok" => true, "admission" => %{"status" => "approved"}} =
             decide(ctx, "alpha", "approved")

    # approved: the house can open a room and get a grant
    room_body =
      JSON.encode!(
        Rooms.build("alpha", "lobby", _pub, 1, %{"policy" => "open"})
        |> Keys.sign_record(priv)
      )

    conn =
      Plug.Test.conn(:post, "/v1/rooms", room_body)
      |> signed(room_body, "alpha", priv)
      |> call()

    assert conn.status == 201

    conn =
      Plug.Test.conn(:post, "/v1/rooms/alpha/lobby/token", body)
      |> signed(body, "alpha", priv)
      |> call()

    assert conn.status == 200

    audit =
      call(
        Plug.Test.conn(:get, "/v1/admin/audit")
        |> admin_signed("", ctx.admin_pub, ctx.admin_priv)
      )

    assert %{"decisions" => [%{"status" => "approved", "handle" => "alpha"}]} =
             JSON.decode!(audit.resp_body)
  end

  test "probation shortens a grant and drops video, record and invite", ctx do
    {pub, priv} = house("alpha")
    decide(ctx, "alpha", "approved")

    room_body =
      JSON.encode!(
        Rooms.build("alpha", "lobby", pub, 1, %{
          "policy" => "open",
          "recording" => "allow",
          "max" => 32
        })
        |> Keys.sign_record(priv)
      )

    conn =
      Plug.Test.conn(:post, "/v1/rooms", room_body)
      |> signed(room_body, "alpha", priv)
      |> call()

    assert conn.status == 201

    decide(ctx, "alpha", "probation", "new house")

    body =
      JSON.encode!(%{"caps" => ["join", "publish_audio", "publish_video", "record", "invite"]})

    conn =
      Plug.Test.conn(:post, "/v1/rooms/alpha/lobby/token", body)
      |> signed(body, "alpha", priv)
      |> call()

    assert conn.status == 200
    response = JSON.decode!(conn.resp_body)
    assert response["caps"] == ["join", "publish_audio"]
    assert response["expires"] - System.system_time(:second) <= 300
  end

  test "a house key cannot act as an administrator", ctx do
    {pub, priv} = house("alpha")

    conn =
      Plug.Test.conn(:get, "/v1/admin/queue")
      |> admin_signed("", pub, priv)
      |> call()

    assert conn.status == 403
  end

  test "an agent review suspends a house and kills its live grant", ctx do
    {pub, priv} = house("alpha")
    decide(ctx, "alpha", "approved")

    room_body =
      JSON.encode!(
        Rooms.build("alpha", "lobby", pub, 1, %{"policy" => "open"})
        |> Keys.sign_record(priv)
      )

    conn =
      Plug.Test.conn(:post, "/v1/rooms", room_body)
      |> signed(room_body, "alpha", priv)
      |> call()

    assert conn.status == 201

    {:ok, grant} = Rooms.grant("alpha", "lobby", %{handle: "alpha"}, %{"caps" => ["join"]})
    assert {:ok, _} = Rooms.verify_grant(grant["grant"])

    body =
      JSON.encode!(%{
        "verdict" => "suspend",
        "detail" => "abuse in a room",
        "evidence" => "jawnos:appt:777"
      })

    conn =
      Plug.Test.conn(:post, "/v1/admin/houses/alpha/review", body)
      |> admin_signed(body, ctx.admin_pub, ctx.admin_priv)
      |> call()

    assert conn.status == 200

    assert %{
             "admission" => %{"status" => "suspended"},
             "review" => %{"verdict" => "suspend"}
           } = JSON.decode!(conn.resp_body)

    assert {:error, :revoked} = Rooms.verify_grant(grant["grant"])

    reviews =
      call(
        Plug.Test.conn(:get, "/v1/admin/reviews")
        |> admin_signed("", ctx.admin_pub, ctx.admin_priv)
      )

    assert %{"reviews" => [%{"handle" => "alpha", "verdict" => "suspend"}]} =
             JSON.decode!(reviews.resp_body)
  end
end
