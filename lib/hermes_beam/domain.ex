defmodule HermesBeam.Domain do
  @moduledoc """
  Central Ash Domain for Hermes BEAM.

  Every Ash Resource must be registered here so resources can be queried,
  mutated, and exposed to Ash AI tools and the Livebook dashboard.
  """
  use Ash.Domain

  resources do
    resource HermesBeam.Memory.Scratchpad
    resource HermesBeam.Memory.Episodic
    resource HermesBeam.Skill
    resource HermesBeam.WorkflowLog
  end
end
