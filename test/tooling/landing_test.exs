# tests-for: scripts/land_lib.exs scripts/land_enqueue.exs scripts/land_coordinator.exs scripts/land_status.exs scripts/land_promote.exs
defmodule JGLand.LandingTest do
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  defp script!(name, args) do
    assert {output, 0} =
             System.cmd("elixir", ["scripts/#{name}" | args],
               cd: @root,
               stderr_to_stdout: true
             )

    output
  end

  defp git!(dir, args) do
    assert {output, 0} =
             System.cmd("git", args, cd: dir, stderr_to_stdout: true)

    output
  end

  test "a branch queues, lands on working, and promotes to master" do
    dir = Path.join(System.tmp_dir!(), "jg-land-test-#{System.unique_integer([:positive])}")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    git!(dir, ["init", "-q", "-b", "master"])
    git!(dir, ["config", "user.name", "Land Test"])
    git!(dir, ["config", "user.email", "land-test@example.invalid"])
    File.write!(Path.join(dir, "file.txt"), "base\n")
    git!(dir, ["add", "file.txt"])
    git!(dir, ["commit", "-qm", "base"])
    git!(dir, ["branch", "working"])
    git!(dir, ["switch", "-q", "-c", "agent/test"])
    File.write!(Path.join(dir, "file.txt"), "base\nfeature\n")
    git!(dir, ["commit", "-qam", "test commit"])

    empty = script!("land_status.exs", ["--root", dir])
    assert empty =~ "queue empty"

    queued =
      script!("land_enqueue.exs", ["--root", dir, "--branch", "agent/test", "--trunk", "working"])

    assert queued =~ "queued"

    status = script!("land_status.exs", ["--root", dir])
    assert status =~ "queued"
    assert status =~ "agent/test"

    landed =
      script!("land_coordinator.exs", [
        "--root",
        dir,
        "--trunk",
        "working",
        "--test-cmd",
        "true",
        "--no-push"
      ])

    assert landed =~ "landed"
    assert git!(dir, ["log", "--format=%s", "working"]) =~ "test commit"

    after_status = script!("land_status.exs", ["--root", dir, "--all"])
    assert after_status =~ "landed"

    promoted =
      script!("land_promote.exs", [
        "--root",
        dir,
        "--trunk",
        "working",
        "--main",
        "master",
        "--test-cmd",
        "true",
        "--no-push"
      ])

    assert promoted =~ "promoted"
    assert git!(dir, ["log", "--format=%s", "master"]) =~ "test commit"
  end
end
