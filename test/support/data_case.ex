defmodule HermesBeam.DataCase do
  @moduledoc """
  Test case template for tests that interact with the database.
  Wraps each test in a transaction that is rolled back on completion.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      alias HermesBeam.Repo
      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import HermesBeam.DataCase
    end
  end

  setup tags do
    HermesBeam.DataCase.setup_sandbox(tags)
    :ok
  end

  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(HermesBeam.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end
end
