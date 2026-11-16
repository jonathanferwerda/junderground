# tests-for: lib/junderground/constructs.ex lib/junderground/lexicon.ex
defmodule Junderground.ConstructsTest do
  use ExUnit.Case, async: true

  alias Junderground.Constructs

  test "suggestions are jawnos' social construct defaults" do
    assert Constructs.suggestions() == %{
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

  test "a blank construct is not part of the scope" do
    assert {:ok, %{"events" => "christmas"}} =
             Constructs.normalize(%{"events" => "christmas", "communities" => "", "clubs" => nil})
  end

  test "an empty dial is universal" do
    assert {:ok, %{}} = Constructs.normalize(%{})
    assert Constructs.matches?(%{}, %{})
    assert Constructs.matches?(%{}, %{"events" => "christmas"})
  end

  test "a room matches when its scope sits inside the dial" do
    assert Constructs.matches?(
             %{"events" => "christmas"},
             %{"events" => "christmas", "communities" => "warwick"}
           )

    refute Constructs.matches?(
             %{"events" => "christmas", "communities" => "warwick"},
             %{"events" => "christmas"}
           )

    refute Constructs.matches?(%{"events" => "christmas"}, %{"events" => "halloween"})
  end

  test "a scope id is stable and changes with a value" do
    a = Constructs.scope_id(%{"events" => "christmas"})
    assert a == Constructs.scope_id(%{"events" => "christmas"})
    refute a == Constructs.scope_id(%{"events" => "halloween"})
    refute a == Constructs.scope_id(%{})
  end

  test "unknown kinds are refused" do
    assert Constructs.normalize(%{"nonsense" => "x"}) == {:error, :bad_constructs}
  end
end
