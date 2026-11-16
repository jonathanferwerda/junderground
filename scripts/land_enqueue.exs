# Put one committed branch in the junderground landing queue.
#
#   elixir scripts/land_enqueue.exs --trunk working
#   elixir scripts/land_enqueue.exs --branch agent/tooling --reason "agent tooling"
#   elixir scripts/land_enqueue.exs --trunk working --wait --timeout 300
#   elixir scripts/land_enqueue.exs --backup
#
# Run from the worktree whose branch should land. The branch must be committed
# and the worktree clean. The ticket is a snapshot of the branch sha; re-running
# for the same queued branch refreshes that snapshot and keeps its place.
#
# `--backup` pushes the branch to origin before writing the ticket. It is off by
# default so a local box never needs network access to queue work.
#
# The coordinator drains the queue; this script never pushes the trunk and never
# restarts anything. With --wait the exit is 0 landed, 1 refused, 2 no verdict.

Code.require_file("land_lib.exs", __DIR__)

defmodule JGLand.Enqueue do
  alias JGLand, as: L

  def main(argv) do
    {opts, args, invalid} =
      OptionParser.parse(argv,
        strict: [
          branch: :string,
          trunk: :string,
          reason: :string,
          agent: :string,
          root: :string,
          wait: :boolean,
          timeout: :integer,
          max_queue: :integer,
          json: :boolean,
          backup: :boolean,
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
        branch = opts[:branch] || L.current_branch(root)
        trunk = opts[:trunk] || "working"
        max_queue = opts[:max_queue] || 12

        run(root, branch, trunk, max_queue, opts)
    end
  rescue
    error ->
      IO.puts(:stderr, "land_enqueue: #{Exception.message(error)}")
      System.halt(2)
  end

  defp run(root, branch, trunk, max_queue, opts) do
    cond do
      not L.branch_exists?(root, branch) ->
        fail("branch does not exist: #{branch}")

      branch == trunk ->
        fail("refusing to queue the trunk branch itself: #{branch}")

      not L.branch_exists?(root, trunk) ->
        fail("trunk branch does not exist: #{trunk} (create it from master first)")

      not L.clean?(root) ->
        fail("worktree is not clean; commit or stash before enqueueing")

      true ->
        :ok
    end

    sha = L.sha(root, branch)

    if opts[:backup] do
      case L.git(root, ["push", "-u", "origin", branch]) do
        {_out, 0} -> :ok
        {out, code} -> fail("branch backup failed (#{code}): #{L.tail(out, 8)}")
      end
    end

    live =
      root
      |> L.tickets()
      |> Enum.filter(&(&1["branch"] == branch and &1["status"] in ["queued", "landing"]))

    cond do
      Enum.any?(live, &(&1["status"] == "landing")) ->
        fail("branch is already landing: #{branch}")

      existing = Enum.find(live, &(&1["status"] == "queued")) ->
        ticket =
          existing
          |> Map.put("sha", sha)
          |> Map.put("trunk", trunk)
          |> Map.put("reason", opts[:reason] || L.last_subject(root, branch))
          |> Map.put("agent", opts[:agent] || System.get_env("USER") || "unknown")
          |> Map.put("status", "queued")
          |> Map.put("message", "refreshed")
          |> Map.put("updated", L.now())

        L.write_ticket(root, ticket)
        L.event(root, %{"id" => ticket["id"], "branch" => branch, "status" => "queued", "message" => "refreshed"})
        report(root, ticket, "refreshed", opts)

      length(Enum.filter(L.tickets(root), &(&1["status"] == "queued"))) >= max_queue ->
        fail("queue is full (#{max_queue} queued); wait for the coordinator")

      true ->
        ticket = %{
          "id" => L.next_id(root),
          "branch" => branch,
          "sha" => sha,
          "trunk" => trunk,
          "reason" => opts[:reason] || L.last_subject(root, branch),
          "agent" => opts[:agent] || System.get_env("USER") || "unknown",
          "created" => L.now(),
          "updated" => L.now(),
          "status" => "queued",
          "message" => "",
          "attempts" => 0
        }

        L.write_ticket(root, ticket)
        L.event(root, %{"id" => ticket["id"], "branch" => branch, "status" => "queued", "message" => "queued"})
        report(root, ticket, "queued", opts)
    end
  end

  defp report(root, ticket, verb, opts) do
    if opts[:wait] && !opts[:json] do
      IO.puts("#{verb} #{ticket["id"]}  #{ticket["branch"]} -> #{ticket["trunk"]}  #{L.short_sha(ticket["sha"])}  #{ticket["reason"]}")
      wait(root, ticket["id"], ticket["branch"], (opts[:timeout] || 300))
    else
      if opts[:json] do
        IO.puts(JSON.encode!(Map.merge(ticket, %{"verb" => verb})))
      else
        IO.puts("#{verb} #{ticket["id"]}  #{ticket["branch"]} -> #{ticket["trunk"]}  #{L.short_sha(ticket["sha"])}  #{ticket["reason"]}")
      end

      if opts[:wait] do
        wait(root, ticket["id"], ticket["branch"], (opts[:timeout] || 300))
      else
        System.halt(0)
      end
    end
  end

  defp wait(root, id, branch, timeout) do
    deadline = System.monotonic_time(:second) + timeout
    poll(root, id, branch, deadline)
  end

  defp poll(root, id, branch, deadline) do
    case L.find_ticket(root, id: id) do
      nil ->
        IO.puts(:stderr, "land_enqueue: ticket #{id} disappeared")
        System.halt(2)

      %{"status" => "landed"} = ticket ->
        IO.puts("landed  #{id}  #{branch}  #{L.short_sha(ticket["sha"])}")
        System.halt(0)

      %{"status" => "refused"} = ticket ->
        IO.puts(:stderr, "refused #{id}  #{branch}: #{ticket["message"]}")
        System.halt(1)

      _ ->
        if System.monotonic_time(:second) >= deadline do
          IO.puts(:stderr, "queued, no verdict yet: #{id}  #{branch}")
          System.halt(2)
        else
          Process.sleep(1_000)
          poll(root, id, branch, deadline)
        end
    end
  end

  defp fail(message) do
    IO.puts(:stderr, "land_enqueue: #{message}")
    System.halt(1)
  end

  defp usage(code) do
    IO.puts("""
    usage: elixir scripts/land_enqueue.exs [options]

      --branch NAME     branch to queue (default: the current branch)
      --trunk NAME      target branch (default: working)
      --reason TEXT     ticket reason (default: the branch tip subject)
      --agent NAME      who queued it (default: USER)
      --backup          push the branch to origin before queueing
      --wait            wait for the coordinator's verdict
      --timeout N       wait bound in seconds (default: 300)
      --max-queue N     refuse when N tickets are already queued (default: 12)
      --root DIR        operate on another checkout (tests)
      --json            one JSON object instead of a text line

      exit: 0 queued/landed, 1 refused, 2 usage or no verdict
    """)

    System.halt(code)
  end
end

JGLand.Enqueue.main(System.argv())
