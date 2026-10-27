defmodule Junderground.PeersTest do
  use ExUnit.Case, async: false

  alias Junderground.{Admin, Keys, Peers}

  setup do
    dir = Path.join(System.tmp_dir!(), "jg-peers-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    {admin_pub, admin_priv} = Keys.generate()
    Application.put_env(:junderground, :admin_keys, [admin_pub])

    start_supervised!({Peers, data_dir: dir})

    on_exit(fn ->
      Application.put_env(:junderground, :admin_keys, [])
      File.rm_rf(dir)
    end)

    {pub, priv} = Keys.generate()
    %{pub: pub, priv: priv, admin_pub: admin_pub, admin_priv: admin_priv}
  end

  defp record(name, url, pub, priv, seq \\ 1, fields \\ %{}) do
    %{
      "format" => "junderground-peer",
      "version" => 1,
      "name" => name,
      "url" => url,
      "pubkey" => pub,
      "seq" => seq,
      "issued" => System.system_time(:second)
    }
    |> Map.merge(fields)
    |> Keys.sign_record(priv)
  end

  test "a new peer is pending; an administrator crest is approved", %{
    pub: pub,
    priv: priv,
    admin_pub: admin_pub,
    admin_priv: admin_priv
  } do
    assert {:ok, %{status: "pending"}} =
             Peers.register(record("Far House", "https://far.example", pub, priv))

    assert {:ok, %{status: "approved"}} =
             Peers.register(record("Admin House", "https://admin.example", admin_pub, admin_priv))
  end

  test "a peer updates its route with seq and prev", %{pub: pub, priv: priv} do
    first = record("Far House", "https://far.example", pub, priv)
    assert {:ok, %{id: id}} = Peers.register(first)

    second =
      record("Far House", "https://far2.example", pub, priv, 2, %{"prev" => first["sig"]})

    assert {:ok, %{id: ^id}} = Peers.register(second)
    assert {:ok, peer} = Peers.get(id)
    assert peer["record"]["url"] == "https://far2.example"

    bad = record("Far House", "https://x.example", pub, priv, 4, %{"prev" => second["sig"]})
    assert {:error, :gap} = Peers.register(bad)
  end

  test "approval, probation and suspension move mirroring rights", %{pub: pub, priv: priv} do
    {:ok, %{id: id}} = Peers.register(record("Far House", "https://far.example", pub, priv))

    refute Peers.admitted?(id)

    {:ok, _} = Peers.decide(id, "approved", "agent", "checked", 0)
    assert Peers.admitted?(id)
    assert Peers.may_mirror?(id)

    {:ok, _} = Peers.decide(id, "probation", "agent", "watch", 0)
    assert Peers.admitted?(id)
    refute Peers.may_mirror?(id)

    {:ok, _} = Peers.decide(id, "suspended", "agent", "abuse", 0)
    refute Peers.admitted?(id)

    {:ok, audit} = Peers.audit(0)
    assert Enum.map(audit, & &1["status"]) == ["approved", "probation", "suspended"]
  end

  test "the queue shows pending peers", %{pub: pub, priv: priv} do
    {:ok, _} = Peers.register(record("Far House", "https://far.example", pub, priv))
    assert %{"pending" => [%{"name" => "Far House"}], "probation" => []} = Peers.queue()
  end

  test "a peer signature is checked against the peer key", %{pub: pub, priv: priv} do
    assert Keys.verify_record(record("Far House", "https://far.example", pub, priv))
    assert Admin.admin_key?(pub) == false
  end
end
