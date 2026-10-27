defmodule Junderground.ConstructsTest do
  use ExUnit.Case, async: true

  alias Junderground.Constructs

  @sorted_values [
    "chess",
    "harbour",
    "sole",
    "now",
    "civic",
    "house",
    "self",
    "home",
    "life",
    "family",
    "market"
  ]
  @default_values [
    "peers",
    "local",
    "sole",
    "now",
    "civic",
    "house",
    "self",
    "home",
    "life",
    "family",
    "market"
  ]

  test "defaults are jawnos' social construct defaults" do
    assert Constructs.defaults() == %{
             "communities" => "local",
             "clubs" => "peers",
             "teams" => "family",
             "people" => "self",
             "projects" => "life",
             "institutions" => "house",
             "governments" => "civic",
             "corporations" => "sole",
             "places" => "home",
             "vendors" => "market",
             "events" => "now"
           }
  end

  test "the channel is the sorted tuple the Mail dial uses" do
    assert Constructs.channel(%{"communities" => "harbour", "clubs" => "chess"}) ==
             Enum.join(@sorted_values, <<0x1F>>)
  end

  test "missing kinds take their defaults" do
    assert Constructs.channel(%{}) == Enum.join(@default_values, <<0x1F>>)
  end

  test "a different value is a different channel" do
    refute Constructs.channel_id(%{"communities" => "a"}) ==
             Constructs.channel_id(%{"communities" => "b"})
  end

  test "unknown kinds are refused" do
    assert Constructs.normalize(%{"nonsense" => "x"}) == {:error, :bad_constructs}
  end

  test "a dial fills in every kind" do
    assert {:ok, full} = Constructs.normalize(%{"communities" => "harbour"})
    assert map_size(full) == 11
    assert full["communities"] == "harbour"
    assert full["clubs"] == "peers"
  end
end
