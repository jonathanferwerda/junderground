defmodule Junderground.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:junderground, :serve, true) do
        [
          Junderground.Nonces,
          {Junderground.Admission, []},
          {Junderground.Directory, []},
          {Junderground.Rooms, []},
          {Bandit,
           plug: Junderground.Router, port: Application.get_env(:junderground, :port, 4100)}
        ]
      else
        []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: Junderground.Supervisor)
  end
end
