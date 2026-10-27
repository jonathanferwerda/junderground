defmodule Junderground.CanonicalTest do
  use ExUnit.Case, async: true

  alias Junderground.Canonical

  test "keys are sorted byte-wise and there is no whitespace" do
    assert Canonical.encode(%{"b" => 2, "a" => "x", "c" => [1, "y"], "d" => %{"z" => -1}}) ==
             ~s({"a":"x","b":2,"c":[1,"y"],"d":{"z":-1}})
  end

  test "strings escape the way JSON::PP canonical does" do
    value = "a\"b\\c\nd\te"
    assert Canonical.encode(%{"k" => value}) == "{\"k\":\"a\\\"b\\\\c\\nd\\te\"}"
  end

  test "control characters use \\u00XX" do
    assert Canonical.encode(%{"k" => <<1>>}) == "{\"k\":\"\\u0001\"}"
  end

  test "floats and booleans are refused, so signed bytes stay portable" do
    assert_raise ArgumentError, fn -> Canonical.encode(%{"k" => 1.5}) end
    assert_raise ArgumentError, fn -> Canonical.encode(%{"k" => true}) end
    assert_raise ArgumentError, fn -> Canonical.encode(%{k: "atom key"}) end
  end
end
