defmodule Junderground do
  @moduledoc """
  junderground is a switch for houses that run jawnos: a signed directory of
  who a house is and where it can be reached, plus short-lived room grants for
  WebRTC calls between houses, communities, clubs, teams and projects.

  It is a separate service. It does not run jawnos, and it carries no PSTN,
  emergency-calling or carrier obligations; see `docs/API.md` for the boundary.
  """

  @version "0.1.8"

  def version, do: @version
end
