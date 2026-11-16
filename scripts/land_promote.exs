# Promote the working trunk to the stable branch, after the full suite.
#
#   elixir scripts/land_promote.exs --once
#   elixir scripts/land_promote.exs --once --dry-run
#   elixir scripts/land_promote.exs --once --no-push
#
# `working` is where the coordinator lands tickets; `master` is what the app
# runs. A promotion is a fast-forward only: master must be an ancestor of
# working. The script takes the land lock, runs the full suite in a scratch
# worktree at the working tip, moves master, then pushes it unless --no-push.
#
# Exit: 0 promoted or already up to date, 1 refused, 2 usage or lock busy.

Code.require_file("land_lib.exs", __DIR__)

defmodule JGLand.Promote do
  alias JGLand, as: L

  def main(argv) do
    {opts, args, invalid} =
      OptionParser.parse(argv,
        strict: [
          trunk: :string,
          main: :string,
          root: :string,
          once: :boolean,
          dry_run: :boolean,
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
        main = opts[:main] || "master"
        test_cmd = opts[:test_cmd] || "mix test"
        timeout = opts[:timeout] || 1_800
        push? = !opts[:no_push]

        unless L.clean?(root) do
          fail("authority checkout is not clean; refuse to move it")
        end

        unless L.branch_exists?(root, main) do
          fail("stable branch does not exist: #{main}")
        end

        unless L.branch_exists?(root, trunk) do
          fail("trunk branch does not exist: #{trunk} (create it from #{main} first)")
        end

        trunk_sha = L.sha(root, trunk)
        main_sha = L.sha(root, main)

        cond do
          trunk_sha == main_sha ->
            IO.puts("#{main} is already at #{trunk} (#{L.short_sha(trunk_sha)})")
            System.halt(0)

          !L.ancestor?(root, main, trunk) ->
            fail("#{main} is not an ancestor of #{trunk}; promotion must be a fast-forward")

          opts[:dry_run] ->
            IO.puts("would promote #{main} #{L.short_sha(main_sha)} -> #{trunk} #{L.short_sha(trunk_sha)}")
            IO.puts("suite: #{test_cmd}")
            IO.puts("push: #{if push?, do: "origin #{main}", else: "no (--no-push)"}")
            System.halt(0)

          true ->
            case L.with_lock(root, timeout, fn -> promote(root, trunk, main, test_cmd, push?) end) do
              {:error, :busy} ->
                IO.puts(:stderr, "land_promote: another landing holds the lock; nothing promoted")
                System.halt(2)

              :ok ->
                System.halt(0)

              :refused ->
                System.halt(1)
            end
        end
    end
  rescue
    error ->
      IO.puts(:stderr, "land_promote: #{Exception.message(error)}")
      System.halt(2)
  end

  defp promote(root, trunk, main, test_cmd, push?) do
    scratch = Path.join(root, ".land/promote-#{System.system_time(:second)}")

    case L.worktree_add(root, scratch, trunk) do
      {:ok, _} ->
        try do
          {out, code} = L.run_tests(root, scratch, test_cmd)
          L.write_log(root, "promote", out)

          if code != 0 do
            IO.puts(:stderr, "land_promote: full suite failed; #{main} not moved")
            IO.puts(:stderr, L.tail(out, 20))
            :refused
          else
            move_and_push(root, trunk, main, push?)
          end
        after
          L.worktree_remove(root, scratch)
        end

      {:error, {_code, out}} ->
        IO.puts(:stderr, "land_promote: cannot create the scratch worktree: #{L.tail(out, 8)}")
        :refused
    end
  end

  defp move_and_push(root, trunk, main, push?) do
    current = L.current_branch(root)

    move =
      if current == main do
        if L.clean?(root) do
          L.git(root, ["merge", "--ff-only", trunk])
        else
          {0, 1}
        end
      else
        L.git(root, ["branch", "-f", main, trunk])
      end

    case move do
      {_out, 0} ->
        if push? do
          case L.git(root, ["push", "origin", "#{trunk}:refs/heads/#{main}"],
                 env: [{"JG_SUITE_ALREADY_RUN", "1"}]) do
            {_out, 0} ->
              IO.puts("promoted #{main} -> #{trunk} (#{L.short_sha(L.sha(root, trunk))}); pushed")
              :ok

            {out, _code} ->
              IO.puts(:stderr, "land_promote: local #{main} moved, push failed: #{L.tail(out, 8)}")
              :refused
          end
        else
          IO.puts("promoted #{main} -> #{trunk} (#{L.short_sha(L.sha(root, trunk))}); not pushed (--no-push)")
          :ok
        end

      {out, _code} ->
        IO.puts(:stderr, "land_promote: could not fast-forward #{main}: #{L.tail(out, 8)}")
        :refused
    end
  end

  defp fail(message) do
    IO.puts(:stderr, "land_promote: #{message}")
    System.halt(2)
  end

  defp usage(code) do
    IO.puts("""
    usage: elixir scripts/land_promote.exs [options]

      --trunk NAME      integration branch (default: working)
      --main NAME       stable branch (default: master)
      --once            accepted for a timer; this is the default action
      --dry-run         print the plan, change nothing
      --no-push         move the local stable branch but do not push origin
      --test-cmd CMD    full-suite command (default: mix test)
      --timeout N       lock wait in seconds (default: 1800)
      --root DIR        operate on another checkout (tests)

      exit: 0 promoted/up to date, 1 refused, 2 usage or lock busy
    """)

    System.halt(code)
  end
end

JGLand.Promote.main(System.argv())
