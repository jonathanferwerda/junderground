# tests-for: scripts/agent_help.exs
defmodule JGTool.AgentHelpTest do
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  defp run(args) do
    System.cmd("elixir", ["scripts/agent_help.exs" | args], cd: @root, stderr_to_stdout: true)
  end

  test "a module brief carries its sources, stores, api, tests and docs" do
    assert {output, 0} = run(["Junderground.Rooms"])

    assert output =~ "sources"
    assert output =~ "rooms.dets"
    assert output =~ "Rooms.grant/4"
    assert output =~ "test/rooms_test.exs"
    assert output =~ "docs/API.md"
  end

  test "a domain routes listing prints exact rows with the router line" do
    assert {output, 0} = run(["--routes", "rooms"])

    assert output =~ "POST /v1/rooms/:handle/:room/token"
    assert output =~ "lib/junderground/router.ex:411"
  end

  test "--check agrees with the committed index" do
    assert File.exists?(Path.join(@root, "docs/AGENT-INDEX.md"))
    assert {_output, 0} = run(["--check"])
  end

  test "an unknown name exits 1" do
    assert {output, 1} = run(["no_such_jg_name"])
    assert output =~ "no such name"
  end
end
