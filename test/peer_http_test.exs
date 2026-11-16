# tests-for: lib/junderground/router.ex lib/junderground/peers.ex
defmodule Junderground.PeerHttpTest do
  use ExUnit.Case, async: false

  alias Junderground.{Admin, Admission, Auth, Directory, Keys, Nonces, Peers, Router, ServerKey}

  setup do
    dir = Path.join(System.tmp_dir!(), "jg-peerhttp-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Application.put_env(:junderground, :data_dir, dir)
    ServerKey.reset()

    {admin_pub, admin_priv} = Keys.generate()
    Application.put_env(:junderground, :admin_keys, [admin_pub])

    start_supervised!(Nonces)
    start_supervised!({Admission, data_dir: dir})
    start_supervised!({Directory, data_dir: dir})
    start_supervised!({Peers, data_dir: dir})

    on_exit(fn ->
      Application.put_env(:junderground, :data_dir, "tmp/test-data")
      Application.put_env(:junderground, :admin_keys, [])
      ServerKey.reset()
      File.rm_rf(dir)
    end)

    %{admin_pub: admin_pub, admin_priv: admin_priv}
  end

  defp call(conn), do: Router.call(conn, [])

  defp signed(conn, body, header, key, priv) do
    timestamp = Integer.to_string(System.system_time(:second))
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    sig =
      Auth.message(conn, body, timestamp, nonce)
      |> then(&:crypto.sign(:eddsa, :none, &1, [priv, :ed25519]))
      |> Base.encode64()

    conn
    |> Plug.Conn.put_req_header(header, key)
    |> Plug.Conn.put_req_header("x-jg-timestamp", timestamp)
    |> Plug.Conn.put_req_header("x-jg-nonce", nonce)
    |> Plug.Conn.put_req_header("x-jg-signature", sig)
  end

  defp peer_record(name, url, pub, priv) do
    %{
      "format" => "junderground-peer",
      "version" => 1,
      "name" => name,
      "url" => url,
      "pubkey" => pub,
      "seq" => 1,
      "issued" => System.system_time(:second)
    }
    |> Keys.sign_record(priv)
  end

  test "a peer is approved through the admin API and may mirror", ctx do
    {pub, priv} = Keys.generate()
    record = peer_record("Far House", "https://far.example", pub, priv)

    conn = call(Plug.Test.conn(:post, "/v1/peers", JSON.encode!(record)))
    assert conn.status == 201
    assert %{"id" => id, "status" => "pending"} = JSON.decode!(conn.resp_body)

    # not listed, and cannot mirror while pending
    conn = call(Plug.Test.conn(:get, "/v1/peers"))
    assert %{"peers" => []} = JSON.decode!(conn.resp_body)

    body = JSON.encode!(%{"records" => []})

    conn =
      Plug.Test.conn(:post, "/v1/mirror", body)
      |> signed(body, "x-jg-peer", pub, priv)
      |> call()

    assert conn.status == 403

    # the administrator approves
    decision = JSON.encode!(%{"status" => "approved", "reason" => "checked"})

    conn =
      Plug.Test.conn(:post, "/v1/admin/peers/#{id}/status", decision)
      |> signed(decision, "x-jg-admin", ctx.admin_pub, ctx.admin_priv)
      |> call()

    assert conn.status == 200

    # it is listed and may mirror
    conn = call(Plug.Test.conn(:get, "/v1/peers"))
    assert %{"peers" => [%{"id" => ^id, "name" => "Far House"}]} = JSON.decode!(conn.resp_body)

    conn =
      Plug.Test.conn(:post, "/v1/mirror", body)
      |> signed(body, "x-jg-peer", pub, priv)
      |> call()

    assert conn.status == 200
  end

  test "a valid signature from an unadmitted key cannot mirror", ctx do
    # the signature is made by the matching private key, so this is not a
    # signature failure: the key simply is not an admitted peer
    {pub, priv} = Keys.generate()
    body = JSON.encode!(%{"records" => []})

    conn =
      Plug.Test.conn(:post, "/v1/mirror", body)
      |> signed(body, "x-jg-peer", pub, priv)
      |> call()

    assert conn.status == 403
    assert Admin.admin_key?(ctx.admin_pub)
    refute Admin.admin_key?(elem(Keys.generate(), 0))
  end
end
