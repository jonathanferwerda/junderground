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

    assert {:ok, :owner} = Rentals.open_for("alpha", "lobby", "alpha", "citizen")
    assert {:error, :not_open} = Rentals.open_for("alpha", "lobby", "beta", "guest")
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

  test "the fee falls with specificity and is flat per rental" do
    Application.put_env(:junderground, :rent_base_fee, 10_000)
    Application.put_env(:junderground, :rent_currency, "CAD")
    Application.put_env(:junderground, :rent_block_seconds, 3_600)
    Application.put_env(:junderground, :rent_rate_percent, [100, 50, 25])

    on_exit(fn ->
      Application.put_env(:junderground, :rent_base_fee, 0)
      Application.put_env(:junderground, :rent_rate_percent, [100, 50, 25])
    end)

    q1 = Rentals.quote(%{"events" => "rock"}, 2)
    q2 = Rentals.quote(%{"events" => "rock", "communities" => "warwick"}, 2)
    q3 = Rentals.quote(%{"events" => "rock", "communities" => "warwick", "teams" => "band"}, 2)

    assert q1["fee"] == 10_000
    assert q1["seconds"] == 7_200
    assert q2["fee"] == 5_000
    assert q3["fee"] == 2_500
  end

  test "the guest window must sit inside the rental", %{pub: pub, priv: priv} do
    now = System.system_time(:second)

    assert {:error, :bad_guest_window} =
             Rentals.create(
               rental(pub, priv, 1, now, now + 3_600, %{
                 "guest_start" => now + 1_800,
                 "guest_end" => now + 7_200
               })
             )
  end
end
