defmodule Junderground.RentalsTest do
  use ExUnit.Case, async: false

  alias Junderground.{Keys, Rentals}

  setup do
    dir = Path.join(System.tmp_dir!(), "jg-rentals-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    start_supervised!({Rentals, data_dir: dir})
    on_exit(fn -> File.rm_rf(dir) end)

    {pub, priv} = Keys.generate()
    %{pub: pub, priv: priv}
  end

  defp rental(pub, priv, seq, start_at, end_at, fields \\ %{}) do
    Rentals.build("alpha", "lobby", pub, seq, start_at, end_at, fields)
    |> Keys.sign_record(priv)
  end

  test "create, list, active and overlap", %{pub: pub, priv: priv} do
    now = System.system_time(:second)

    first =
      rental(pub, priv, 1, now - 60, now + 3600, %{"label" => "Rock Show", "capacity" => 50})

    assert {:ok, view} = Rentals.create(first)
    assert view["label"] == "Rock Show"

    assert {:ok, active} = Rentals.active("alpha", "lobby")
    assert active["id"] == view["id"]

    assert {:ok, [listed]} = Rentals.list("alpha", "lobby")
    assert listed["id"] == view["id"]

    overlap =
      rental(pub, priv, 2, now + 60, now + 7200, %{"prev" => first["sig"]})

    assert {:error, :overlap} = Rentals.create(overlap)

    later =
      rental(pub, priv, 2, now + 7200, now + 9000, %{"prev" => first["sig"]})

    assert {:ok, _} = Rentals.create(later)
  end

  test "outside a window the room is closed; the owner is not", %{
    pub: pub,
    priv: priv
  } do
    now = System.system_time(:second)

    assert {:ok, _} =
             Rentals.create(rental(pub, priv, 1, now + 3600, now + 7200))

    assert {:ok, :owner} = Rentals.open_for("alpha", "lobby", "alpha")
    assert {:error, :not_open} = Rentals.open_for("alpha", "lobby", "beta")
  end

  test "cancel frees the window", %{pub: pub, priv: priv} do
    now = System.system_time(:second)
    {:ok, view} = Rentals.create(rental(pub, priv, 1, now - 60, now + 3600))

    assert {:ok, cancelled} = Rentals.cancel("alpha", "lobby", view["id"])
    assert cancelled["cancelled"] == true
    assert {:ok, []} = Rentals.list("alpha", "lobby")
  end

  test "a window longer than twelve hours is refused", %{pub: pub, priv: priv} do
    now = System.system_time(:second)

    assert {:error, :window_too_long} =
             Rentals.create(rental(pub, priv, 1, now, now + 13 * 3600))
  end
end
