# What is in the junderground landing queue, and what happened to a ticket.
#
#   elixir scripts/land_status.exs
#   elixir scripts/land_status.exs --branch agent/tooling
#   elixir scripts/land_status.exs --id 00000001 --wait --timeout 60
#   elixir scripts/land_status.exs --refused --check
#   elixir scripts/land_status.exs --all
#   elixir scripts/land_status.exs --json
#
# Exit: 0 query/landed, 1 refused or --check found one, 2 no ticket or timeout.

Code.require_file("land_lib.exs", __DIR__)

defmodule JGLand.Status do
  alias JGLand, as: L

  def main(argv) do
    {opts, args, invalid} =
      OptionParser.parse(argv,
        strict: [
          id: :string,
          branch: :string,
          root: :string,
          json: :boolean,
          wait: :boolean,
          timeout: :integer,
          all: :boolean,
          refused: :boolean,
          check: :boolean,
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
        timeout = opts[:timeout] || 60

        if opts[:wait] && (opts[:id] || opts[:branch]) do
          wait(root, opts, timeout)
        else
          list(root, opts)
        end
    end
  rescue
    error ->
      IO.puts(:stderr, "land_status: #{Exception.message(error)}")
      System.halt(2)
  end

  defp list(root, opts) do
    tickets = select(root, opts)

    if tickets == [] do
      cond do
        opts[:json] ->
          IO.puts("[]")

        opts[:id] || opts[:branch] ->
          IO.puts(:stderr, "land_status: no matching ticket")

        true ->
          IO.puts("queue empty")
      end

      System.halt(if opts[:id] || opts[:branch], do: 2, else: 0)
    end

    Enum.each(tickets, &print_ticket(&1, opts))

    refused = Enum.count(tickets, &(&1["status"] == "refused"))
    System.halt(if opts[:check] && refused > 0, do: 1, else: 0)
  end

  defp select(root, opts) do
    all = L.tickets(root)

    cond do
      opts[:id] ->
        Enum.filter(all, &(&1["id"] == opts[:id]))

      opts[:branch] ->
        Enum.filter(all, &(&1["branch"] == opts[:branch]))

      opts[:refused] ->
        Enum.filter(all, &(&1["status"] == "refused"))

      opts[:all] ->
        all

      true ->
        Enum.filter(all, &(&1["status"] in ["queued", "landing"]))
    end
  end

  defp print_ticket(ticket, opts) do
    if opts[:json] do
      IO.puts(JSON.encode!(ticket))
    else
      IO.puts(
        "#{ticket["id"]}  #{pad(ticket["status"], 8)}  #{pad(ticket["branch"], 24)}  " <>
          "#{pad(ticket["trunk"], 8)}  #{L.short_sha(ticket["sha"])}  " <>
          "#{pad(L.age(ticket["updated"] || ticket["created"]), 5)}  #{ticket["reason"]}"
      )

      if ticket["message"] not in ["", nil] do
        IO.puts("          #{ticket["message"]}")
      end
    end
  end

  defp wait(root, opts, timeout) do
    deadline = System.monotonic_time(:second) + timeout
    poll(root, opts, deadline)
  end

  defp poll(root, opts, deadline) do
    case L.find_ticket(root, opts) do
      nil ->
        IO.puts(:stderr, "land_status: no matching ticket")
        System.halt(2)

      %{"status" => "landed"} = ticket ->
        print_ticket(ticket, opts)
        System.halt(0)

      %{"status" => "refused"} = ticket ->
        print_ticket(ticket, opts)
        System.halt(1)

      _ ->
        if System.monotonic_time(:second) >= deadline do
          IO.puts(:stderr, "land_status: no verdict yet")
          System.halt(2)
        else
          Process.sleep(1_000)
          poll(root, opts, deadline)
        end
    end
  end

  defp pad(value, width), do: String.pad_trailing(to_string(value), width)

  defp usage(code) do
    IO.puts("""
    usage: elixir scripts/land_status.exs [options]

      --id ID           one ticket
      --branch NAME     the newest ticket for a branch
      --wait            wait for that ticket's verdict
      --timeout N       wait bound in seconds (default: 60)
      --refused         every refused ticket
      --all             every ticket, including landed and refused
      --check           exit 1 when a refused ticket is waiting
      --json            one JSON object per ticket
      --root DIR        operate on another checkout (tests)

      exit: 0 query/landed, 1 refused or --check found one, 2 no ticket/timeout
    """)

    System.halt(code)
  end
end

JGLand.Status.main(System.argv())
