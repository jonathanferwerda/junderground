# tests-for: scripts/help_audit.exs
defmodule JGTool.HelpAuditTest do
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  defp run(args) do
    System.cmd("elixir", ["scripts/help_audit.exs" | args], cd: @root, stderr_to_stdout: true)
  end

  test "the tree's help topics pass the audit" do
    assert {output, 0} = run(["--json"])
    report = JSON.decode!(output)

    assert report["failures"] == []
    assert report["topics"] == 8
    assert report["routes"] == 54
    assert report["settings"] == 21
    assert report["stores"] == 9
  end

  test "the quiet form hides the coverage summary" do
    assert {output, 0} = run(["--quiet"])
    refute output =~ "every route covered"
  end

  test "the audit names the generated index check" do
    assert {output, 0} = run(["--all"])
    assert output =~ "ok    8 topics, every route covered"
    assert output =~ "admin-and-errors"
  end
end
