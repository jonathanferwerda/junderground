# Drain the junderground landing queue into the working branch.
#
#   elixir scripts/land_coordinator.exs --once
#   elixir scripts/land_coordinator.exs --trunk working --no-push
#   elixir scripts/land_coordinator.exs --test-cmd "mix test"
#
# Run from the authority checkout (the one that should advance). It takes the
# land lock, then for each queued ticket:
#
#   1. creates a detached scratch worktree at the ticket sha under .land/;
#   2. rebases it onto the trunk;
#   3. runs the test command once with the authority's deps/_build shared;
#   4. fast-forwards the local trunk and, unless --no-push, pushes it;
#   5. marks the ticket landed, or refuses it with a class and the log tail.
#
# The scratch worktree is removed either way. Refusals are rebase, suite, push,
# stale, trunk or primary. One ticket's refusal does not stop the rest.

Code.require_file("land_lib.exs", __DIR__)

defmodule JGLand.Coordinator do
  alias JGLand, as: L

  def main(argv) do
    {opts, args, invalid} =
      OptionParser.parse(argv,
        strict: [
          trunk: :string,
          root: :string,
          once: :boolean,
          no_push: :boolean,
          test_cmd: :string,
          timeout: :integer,
          help: :boolean
        ]
      )

    cond do
      invalid != [] or args != [] ->
        usage(2)

      opts[:help] ->
        usage(0)

      true ->
        root = L.root(opts)
        trunk = opts[:trunk] || "working"
        test_cmd = opts[:test_cmd] || "mix test"
        timeout = opts[:timeout] || 300
        push? = !opts[:no_push]

        unless L.branch_exists?(root, trunk) do
          fail("trunk branch does not exist: #{trunk}")
        end

        unless L.clean?(root) do
          fail("authority checkout is not clean; refuse to move it")
        end

        case L.with_lock(root, timeout, fn -> drain(root, trunk, test_cmd, push?) end) do
          {:error, :busy} ->
            IO.puts(:stderr, "land_coordinator: another landing holds the lock; nothing drained")
            System.halt(0)

          _ ->
            System.halt(0)
        end
    end
  rescue
    error ->
      IO.puts(:stderr, "land_coordinator: #{Exception.message(error)}")
      System.halt(2)
  end

  defp drain(root, trunk, test_cmd, push?) do
    queued =
      root
      |> L.tickets()
      |> Enum.filter(&(&1["status"] == "queued"))

    if queued == [] do
      IO.puts("queue empty")
    else
      Enum.each(queued, fn ticket -> land_one(root, trunk, test_cmd, push?, ticket) end)
    end
  end

  defp land_one(root, trunk, test_cmd, push?, ticket) do
    ticket = L.update_ticket(root, ticket, "landing", "coordinator started")
    IO.puts("landing #{ticket["id"]}  #{ticket["branch"]} -> #{trunk}")

    case L.git(root, ["cat-file", "-e", ticket["sha"] <> "^{commit}"]) do
      {_out, 0} ->
        scratch = Path.join(root, ".land/#{ticket["id"]}")

        case L.worktree_add(root, scratch, ticket["sha"]) do
          {:ok, _} ->
            try do
              land_in_scratch(root, trunk, test_cmd, push?, ticket, scratch)
            after
              L.worktree_remove(root, scratch)
            end

          {:error, {_code, out}} ->
            refuse(root, ticket, "worktree", out)
        end

      {out, _code} ->
        refuse(root, ticket, "stale", "commit is not present: #{L.tail(out, 8)}")
    end
  end

  defp land_in_scratch(root, trunk, test_cmd, push?, ticket, scratch) do
    case L.git(scratch, ["rebase", trunk]) do
      {_out, 0} ->
        after_rebase(root, trunk, test_cmd, push?, ticket, scratch)

      {out, _code} ->
        L.git(scratch, ["rebase", "--abort"])
        L.write_log(root, ticket["id"], out)
        refuse(root, ticket, "rebase", out)
    end
  end

  defp after_rebase(root, trunk, test_cmd, push?, ticket, scratch) do
    {out, code} = L.run_tests(root, scratch, test_cmd)
    L.write_log(root, ticket["id"], out)

    if code != 0 do
      refuse(root, ticket, "suite", out)
    else
      new_sha = L.sha(scratch, "HEAD")
      current = L.current_branch(root)

      cond do
        current == trunk && !L.clean?(root) ->
          refuse(root, ticket, "primary", "authority checkout is dirty")

        current == trunk ->
          case L.git(root, ["merge", "--ff-only", new_sha]) do
            {_out, 0} -> push(root, trunk, new_sha, push?, ticket)
            {out, _} -> refuse(root, ticket, "trunk", "could not fast-forward #{trunk}: #{L.tail(out, 8)}")
          end

        true ->
          case L.git(root, ["branch", "-f", trunk, new_sha]) do
            {_out, 0} -> push(root, trunk, new_sha, push?, ticket)
            {out, _} -> refuse(root, ticket, "trunk", "could not move #{trunk}: #{L.tail(out, 8)}")
          end
      end
    end
  end

  defp push(root, trunk, sha, false, ticket) do
    landed(root, ticket, trunk, sha, "suite ok; not pushed (--no-push)")
  end

  defp push(root, trunk, sha, true, ticket) do
    case L.git(root, ["push", "origin", "#{sha}:refs/heads/#{trunk}"],
           env: [{"JG_SUITE_ALREADY_RUN", "1"}]) do
      {_out, 0} ->
        landed(root, ticket, trunk, sha, "suite ok; pushed #{trunk}")

      {out, _code} ->
        refuse(root, ticket, "push", "local #{trunk} moved to #{L.short_sha(sha)}, push failed: #{L.tail(out, 8)}")
    end
  end

  defp landed(root, ticket, trunk, sha, message) do
    L.update_ticket(root, ticket, "landed", message)
    IO.puts("landed  #{ticket["id"]}  #{ticket["branch"]}  #{trunk}  #{L.short_sha(sha)}")
  end

  defp refuse(root, ticket, kind, message) do
    L.update_ticket(root, ticket, "refused", "#{kind}: #{String.slice(message, 0, 800)}")
    IO.puts(:stderr, "refused #{ticket["id"]}  #{ticket["branch"]}  (#{kind})")
    {:refused, kind}
  end

  defp fail(message) do
    IO.puts(:stderr, "land_coordinator: #{message}")
    System.halt(2)
  end

  defp usage(code) do
    IO.puts("""
    usage: elixir scripts/land_coordinator.exs [options]

      --trunk NAME      branch to advance (default: working)
      --test-cmd CMD    command run in the scratch worktree (default: mix test)
      --no-push         update the local trunk but do not push origin
      --timeout N       lock wait in seconds (default: 300)
      --once            accepted for a timer; this is the default action
      --root DIR        operate on another checkout (tests)

      exit: 0 drained (inspect refused tickets with land_status.exs), 2 usage
    """)

    System.halt(code)
  end
end

JGLand.Coordinator.main(System.argv())
