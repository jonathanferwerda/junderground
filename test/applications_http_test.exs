defmodule Junderground.ApplicationsHttpTest do
  use ExUnit.Case, async: false

  alias Junderground.{
    Admission,
    Applications,
    Auth,
    Directory,
    Keys,
    Nonces,
    Record,
    Router,
    ServerKey
  }

  setup do
    dir = Path.join(System.tmp_dir!(), "jg-applications-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Application.put_env(:junderground, :data_dir, dir)
    ServerKey.reset()

    start_supervised!(Nonces)
    start_supervised!({Admission, data_dir: dir})
    start_supervised!({Directory, data_dir: dir})
    start_supervised!({Applications, data_dir: dir})

    on_exit(fn ->
      Application.put_env(:junderground, :data_dir, "tmp/test-data")
      ServerKey.reset()
      File.rm_rf(dir)
    end)

    {pub, priv} = Keys.generate()

    record =
      Record.build("register", "alpha", pub, 1, %{"name" => "Alpha"})
      |> Keys.sign_record(priv)

    conn = call(Plug.Test.conn(:post, "/v1/houses", JSON.encode!(record)))
    assert conn.status == 201
    assert {:ok, _} = Admission.decide("alpha", "approved", "test", "", 0)

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

  defp application(overrides \\ %{}) do
    Map.merge(
      %{
        "name" => "Dana",
        "email" => "dana@example.test",
        "phone" => "555-0100",
        "roles" => ["sales"],
        "interview" => "Tuesday at ten",
        "trial" => "A short page of work",
        "description" => "I would like to work the counter.",
        "consent" => "on"
      },
      overrides
    )
  end

  defp apply_for(handle, body) do
    call(Plug.Test.conn(:post, "/v1/apply/#{handle}", JSON.encode!(body)))
  end

  test "an applicant applies without a house identity" do
    conn = apply_for("alpha", application())
    assert conn.status == 202
    body = JSON.decode!(conn.resp_body)
    assert body["ok"] == true
    assert body["status"] == "received"
    assert is_binary(body["id"]) and byte_size(body["id"]) == 32
    assert is_binary(body["token"]) and byte_size(body["token"]) > 20
  end

  test "the house collects the application and never sees its token", %{priv: priv} do
    %{"id" => id} = JSON.decode!(apply_for("alpha", application()).resp_body)

    conn = call(signed(Plug.Test.conn(:get, "/v1/houses/alpha/applications"), "", "alpha", priv))
    assert conn.status == 200
    body = JSON.decode!(conn.resp_body)
    assert [app] = body["applications"]
    assert app["id"] == id
    assert app["name"] == "Dana"
    assert app["roles"] == ["sales"]
    refute Map.has_key?(app, "token")
    refute Map.has_key?(app, "ip_hash")
  end

  test "the applicant's token reads the answer, and a wrong token does not" do
    %{"id" => id, "token" => token} = JSON.decode!(apply_for("alpha", application()).resp_body)

    conn = call(Plug.Test.conn(:get, "/v1/apply/#{id}?token=#{token}"))
    assert conn.status == 200
    assert JSON.decode!(conn.resp_body)["status"] == "received"

    conn = call(Plug.Test.conn(:get, "/v1/apply/#{id}?token=wrong"))
    assert conn.status == 403

    conn = call(Plug.Test.conn(:get, "/v1/apply/#{id}"))
    assert conn.status == 403
  end

  test "the house decides, and the applicant sees it", %{priv: priv} do
    %{"id" => id, "token" => token} = JSON.decode!(apply_for("alpha", application()).resp_body)
    body = JSON.encode!(%{"status" => "approved"})

    conn =
      call(
        signed(
          Plug.Test.conn(:post, "/v1/houses/alpha/applications/#{id}/status", body),
          body,
          "alpha",
          priv
        )
      )

    assert conn.status == 200
    assert JSON.decode!(conn.resp_body)["application"]["status"] == "approved"

    conn = call(Plug.Test.conn(:get, "/v1/apply/#{id}?token=#{token}"))
    body = JSON.decode!(conn.resp_body)
    assert body["status"] == "approved"
    assert is_integer(body["decided"])
  end

  test "a request without consent is refused" do
    conn = apply_for("alpha", application(%{"consent" => "off"}))
    assert conn.status == 422
  end

  test "an unknown or unadmitted house is refused" do
    assert apply_for("nobody", application()).status == 404

    {pub, priv} = Keys.generate()

    record =
      Record.build("register", "beta", pub, 1, %{"name" => "Beta"})
      |> Keys.sign_record(priv)

    assert call(Plug.Test.conn(:post, "/v1/houses", JSON.encode!(record))).status == 201
    assert apply_for("beta", application()).status == 404
  end

  test "another house cannot read or decide alpha's applications" do
    %{"id" => id} = JSON.decode!(apply_for("alpha", application()).resp_body)
    {pub, priv} = Keys.generate()

    record =
      Record.build("register", "beta", pub, 1, %{"name" => "Beta"})
      |> Keys.sign_record(priv)

    call(Plug.Test.conn(:post, "/v1/houses", JSON.encode!(record)))
    Admission.decide("beta", "approved", "test", "", 0)

    conn = call(signed(Plug.Test.conn(:get, "/v1/houses/alpha/applications"), "", "beta", priv))
    assert conn.status == 403

    body = JSON.encode!(%{"status" => "approved"})

    conn =
      call(
        signed(
          Plug.Test.conn(:post, "/v1/houses/alpha/applications/#{id}/status", body),
          body,
          "beta",
          priv
        )
      )

    assert conn.status == 403
  end
end
