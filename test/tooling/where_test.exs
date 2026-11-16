# tests-for: scripts/where.exs
defmodule JGTool.WhereTest do
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  defp run(args) do
    System.cmd("elixir", ["scripts/where.exs" | args], cd: @root, stderr_to_stdout: true)
  end

  test "a function name prints its location and arity" do
    assert {output, 0} = run(["Rooms.grant"])
    assert output =~ "lib/junderground/rooms.ex:75  Rooms.grant/4"
  end

  test "a quoted route prints its line and the calls it makes" do
    assert {output, 0} = run(["POST /v1/rooms/:handle/:room/token"])
    assert output =~ "lib/junderground/router.ex:411"
    assert output =~ "Rooms.grant/4"
  end

  test "an error atom prints its status clause" do
    assert {output, 0} = run([":ticket_spent"])
    assert output =~ "lib/junderground/router.ex:1247"
    assert output =~ ":ticket_spent -> 409"
  end

  test "a setting prints its config line and environment name" do
    assert {output, 0} = run(["sfu_url"])
    assert output =~ "config/runtime.exs:21"
    assert output =~ "JG_SFU_URL"
  end

  test "a test file resolves to its module" do
    assert {output, 0} = run(["test/rooms_test.exs"])
    assert output =~ "Junderground.RoomsTest"
  end

  test "the outline lists both modules in a shared file" do
    assert {output, 0} = run(["--outline", "lib/junderground/signaling.ex"])
    assert output =~ ~r/^\d+\tmodule Junderground\.Signaling$/m
    assert output =~ ~r/^\d+\tmodule Junderground\.Signaling\.Protocol$/m
  end

  test "a miss exits 1 and suggests the near name" do
    # Build the typo at runtime: the locator falls back to mention lines in
    # test/**/*.exs, so a literal here would make it find this file and exit 0.
    typo = Enum.join(["r", "oo", "oms"])

    assert {output, 1} = run([typo])
    assert output =~ ~r/near\s+Rooms/
  end

  test "terse prints only the location" do
    assert {output, 0} = run(["--terse", "Rooms.grant"])
    assert String.trim(output) == "lib/junderground/rooms.ex:75"
  end
end
