defmodule JGLand do
  @moduledoc """
  Shared plumbing for the junderground landing queue.

  The queue lives in `<git-common-dir>/land-queue/`, so every worktree of one
  clone sees the same tickets. Scratch worktrees and logs live under `.land/`
  in the authority checkout. Nothing here boots the application.
  """

  def now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  def root(opts \\ []) do
    case Keyword.get(opts, :root) do
      nil -> git!(nil, ["rev-parse", "--show-toplevel"])
      path -> Path.expand(path)
    end
  end

  def git(root, args, opts \\ []) do
    System.cmd("git", args, [cd: root || File.cwd!(), stderr_to_stdout: true] ++ opts)
  end

  def git!(root, args, opts \\ []) do
    case git(root, args, opts) do
      {out, 0} ->
        String.trim(out)

      {out, code} ->
        raise "git #{Enum.join(args, " ")} failed (#{code}): #{String.trim(out)}"
    end
  end

  def common_dir(root) do
    path = git!(root, ["rev-parse", "--git-common-dir"])
    if Path.type(path) == :absolute, do: path, else: Path.expand(path, root)
  end

  def queue_dir(root) do
    dir = Path.join(common_dir(root), "land-queue")
    File.mkdir_p!(dir)
    dir
  end

  def log_path(root, id), do: Path.join(queue_dir(root), "#{id}.log")
  def events_path(root), do: Path.join(queue_dir(root), "events.jsonl")
  def lock_path(root), do: Path.join(common_dir(root), "junderground-land.lock")

  def tickets(root) do
    root
    |> queue_dir()
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.map(&read_ticket/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1["id"])
  end

  def read_ticket(path) do
    path |> File.read!() |> JSON.decode!()
  rescue
    _ -> nil
  end

  def write_ticket(root, ticket) do
    path = Path.join(queue_dir(root), ticket["id"] <> ".json")
    tmp = path <> ".tmp"
    File.write!(tmp, JSON.encode!(ticket) <> "\n")
    File.rename!(tmp, path)
    path
  end

  def update_ticket(root, ticket, status, message \\ "") do
    updated =
      ticket
      |> Map.put("status", status)
      |> Map.put("message", message)
      |> Map.put("updated", now())

    write_ticket(root, updated)

    event(root, %{
      "id" => ticket["id"],
      "branch" => ticket["branch"],
      "status" => status,
      "message" => message
    })

    updated
  end

  def event(root, fields) do
    line = JSON.encode!(Map.put(fields, "at", now())) <> "\n"
    File.write!(events_path(root), line, [:append])
  end

  def next_id(root) do
    next =
      root
      |> tickets()
      |> Enum.map(fn t -> String.to_integer(t["id"]) end)
      |> Enum.max(fn -> 0 end)
      |> Kernel.+(1)

    next |> Integer.to_string() |> String.pad_leading(8, "0")
  end

  def find_ticket(root, opts) do
    list = tickets(root)

    cond do
      id = opts[:id] -> Enum.find(list, &(&1["id"] == id))
      branch = opts[:branch] -> list |> Enum.filter(&(&1["branch"] == branch)) |> List.last()
      true -> nil
    end
  end

  def current_branch(root) do
    git!(root, ["rev-parse", "--abbrev-ref", "HEAD"])
  end

  def branch_exists?(root, branch) do
    match?({_, 0}, git(root, ["show-ref", "--verify", "--quiet", "refs/heads/#{branch}"]))
  end

  def sha(root, ref), do: git!(root, ["rev-parse", ref])
  def short_sha(sha), do: String.slice(sha, 0, 10)

  def ancestor?(root, ancestor, descendant) do
    match?({_, 0}, git(root, ["merge-base", "--is-ancestor", ancestor, descendant]))
  end

  def clean?(root) do
    case git(root, ["status", "--porcelain"]) do
      {out, 0} -> String.trim(out) == ""
      _ -> false
    end
  end

  def last_subject(root, ref) do
    git!(root, ["log", "-1", "--format=%s", ref])
  end

  def with_lock(root, timeout, fun) do
    lock = lock_path(root)

    case acquire(lock, timeout) do
      :ok ->
        try do
          fun.()
        after
          File.rm_rf(lock)
        end

      {:error, :busy} ->
        {:error, :busy}
    end
  end

  defp acquire(lock, timeout) do
    case File.mkdir(lock) do
      :ok ->
        File.write!(Path.join(lock, "pid"), System.pid() <> "\n")
        :ok

      {:error, :eexist} ->
        cond do
          stale?(lock) ->
            File.rm_rf!(lock)
            acquire(lock, timeout)

          timeout <= 0 ->
            {:error, :busy}

          true ->
            Process.sleep(1_000)
            acquire(lock, timeout - 1)
        end

      {:error, _} ->
        {:error, :busy}
    end
  end

  defp stale?(lock) do
    case File.stat(lock) do
      {:ok, stat} ->
        mtime =
          stat.mtime
          |> NaiveDateTime.from_erl!()
          |> DateTime.from_naive!("Etc/UTC")
          |> DateTime.to_unix()

        System.system_time(:second) - mtime > 3_600

      _ ->
        true
    end
  end

  def worktree_add(root, dir, ref) do
    File.rm_rf(dir)
    File.mkdir_p!(Path.dirname(dir))

    case git(root, ["worktree", "add", "--detach", dir, ref]) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, code} -> {:error, {code, String.trim(out)}}
    end
  end

  def worktree_remove(root, dir) do
    git(root, ["worktree", "remove", "--force", dir])
    File.rm_rf(dir)
    git(root, ["worktree", "prune"])
    :ok
  end

  def write_log(root, id, text) do
    File.write!(log_path(root, id), text)
  end

  def run_tests(root, dir, command) do
    env = [
      {"MIX_DEPS_PATH", Path.join(root, "deps")},
      {"MIX_BUILD_PATH", Path.join(root, "_build")}
    ]

    System.cmd("sh", ["-lc", command], cd: dir, env: env, stderr_to_stdout: true)
  end

  def tail(text, lines \\ 20) do
    text
    |> String.split("\n")
    |> Enum.take(-lines)
    |> Enum.join("\n")
  end

  def age(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _} ->
        seconds = DateTime.diff(DateTime.utc_now(), at, :second)

        cond do
          seconds < 60 -> "#{seconds}s"
          seconds < 3_600 -> "#{div(seconds, 60)}m"
          true -> "#{div(seconds, 3_600)}h"
        end

      _ ->
        "?"
    end
  end
end
