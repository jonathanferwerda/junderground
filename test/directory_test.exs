defmodule Junderground.DirectoryTest do
  use ExUnit.Case, async: false

  alias Junderground.{Directory, Keys, Record}

  setup do
    dir = Path.join(System.tmp_dir!(), "jg-dir-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    start_supervised!({Directory, data_dir: dir})
    on_exit(fn -> File.rm_rf(dir) end)

    {pub, priv} = Keys.generate()
    %{dir: dir, pub: pub, priv: priv}
  end

  defp rec(kind, pub, priv, seq, fields \\ %{}) do
    Record.build(kind, "alpha", pub, seq, fields) |> Keys.sign_record(priv)
  end

  test "register, append, latest and history", %{pub: pub, priv: priv} do
    first = rec("register", pub, priv, 1, %{"name" => "Alpha"})
    assert {:ok, %{seq: 1}} = Directory.register(first)

    route =
      rec("route", pub, priv, 2, %{
        "prev" => first["sig"],
        "routes" => %{"wss" => "wss://alpha.example/v1"}
      })

    assert {:ok, %{seq: 2}} = Directory.append(route)

    assert {:ok, head} = Directory.latest("alpha")
    assert head["seq"] == 2
    assert head["pubkey"] == pub
    assert head["record"]["routes"]["wss"] == "wss://alpha.example/v1"

    assert {:ok, history} = Directory.history("alpha")
    assert Enum.map(history, & &1["seq"]) == [1, 2]

    assert {:ok, feed} = Directory.feed(0)
    assert length(feed) == 2

    assert Directory.count() == 1
  end

  test "the same record is idempotent, a replayed older one is not", %{pub: pub, priv: priv} do
    first = rec("register", pub, priv, 1)
    assert {:ok, _} = Directory.register(first)
    assert {:ok, :unchanged} = Directory.register(first)

    older = rec("register", pub, priv, 1, %{"issued" => 1_600_000_000})
    assert {:error, :stale} = Directory.register(older)
  end

  test "a mirrored record lands in the feed", %{pub: pub, priv: priv} do
    first = rec("register", pub, priv, 1)
    assert {:ok, [{_, :ok}]} = Directory.mirror([first])
    assert {:ok, feed} = Directory.feed(0)
    assert [^first] = feed
  end

  test "the head survives a restart", %{dir: dir, pub: pub, priv: priv} do
    assert {:ok, _} = Directory.register(rec("register", pub, priv, 1))

    stop_supervised!(Directory)
    start_supervised!({Directory, data_dir: dir})

    assert {:ok, head} = Directory.latest("alpha")
    assert head["seq"] == 1
  end

  test "a retired handle is not live", %{pub: pub, priv: priv} do
    first = rec("register", pub, priv, 1)
    assert {:ok, _} = Directory.register(first)

    tombstone = rec("tombstone", pub, priv, 2, %{"prev" => first["sig"]})
    assert {:ok, _} = Directory.register(tombstone)

    assert {:error, :not_found} = Directory.live("alpha")
    assert {:ok, %{"tombstoned" => true}} = Directory.latest("alpha")
  end
end
