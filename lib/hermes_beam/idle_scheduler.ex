defmodule HermesBeam.IdleScheduler do
  @moduledoc """
  Hub-only GenServer that fires `SyntheticDataReactor` during idle periods.

  Idle is defined as: no `AgentLoop` Reactor has started in the last
  `@idle_threshold_ms` milliseconds. Every `@check_interval_ms` the scheduler
  reads recent `WorkflowLog` entries and, if idle, picks the oldest-explored
  concept domain from the concept list and dispatches a synthetic data run.

  The concept pool is hardcoded for now. In a future phase it will be derived
  automatically from low-confidence episodic memory clusters.
  """
  use GenServer
  require Logger

  @check_interval_ms    5 * 60 * 1_000   # check every 5 minutes
  @idle_threshold_ms    10 * 60 * 1_000  # idle after 10 minutes of no agent activity

  @concept_pool [
    "Erlang distribution and fault tolerance",
    "Elixir pattern matching and data transformation",
    "pgvector similarity search and embedding quality",
    "BEAM scheduler and concurrency primitives",
    "Reactor workflow composition and saga compensation",
    "Ash Framework resource actions and policies",
    "Neural network inference and quantization trade-offs",
    "Tailscale WireGuard mesh networking",
    "Bumblebee model loading and EXLA compilation",
    "Autonomous skill generation and live code compilation"
  ]

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec trigger_for(String.t(), Ecto.UUID.t()) :: :ok
  def trigger_for(concept, agent_id) do
    GenServer.cast(__MODULE__, {:trigger, concept, agent_id})
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    Logger.info("[IdleScheduler] Started. Check interval: #{@check_interval_ms}ms")
    schedule_check()
    {:ok, %{last_trigger_index: 0}}
  end

  @impl true
  def handle_info(:check_idle, state) do
    new_state =
      if cluster_idle?() do
        {concept, next_index} = next_concept(state.last_trigger_index)
        agent_id = default_agent_id()

        Logger.info("[IdleScheduler] Cluster idle — dispatching SyntheticDataReactor for '#{concept}'")

        Task.start(fn ->
          Reactor.run(
            HermesBeam.Workflows.SyntheticDataReactor,
            %{concept_to_explore: concept, agent_id: agent_id}
          )
        end)

        %{state | last_trigger_index: next_index}
      else
        Logger.debug("[IdleScheduler] Cluster active — skipping synthetic run")
        state
      end

    schedule_check()
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:trigger, concept, agent_id}, state) do
    Logger.info("[IdleScheduler] Manual trigger for '#{concept}'")

    Task.start(fn ->
      Reactor.run(
        HermesBeam.Workflows.SyntheticDataReactor,
        %{concept_to_explore: concept, agent_id: agent_id}
      )
    end)

    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp schedule_check do
    Process.send_after(self(), :check_idle, @check_interval_ms)
  end

  defp cluster_idle? do
    import Ecto.Query

    threshold = DateTime.add(DateTime.utc_now(), -@idle_threshold_ms, :millisecond)

    recent_runs =
      from(w in "workflow_logs",
        where: w.workflow_name == "AgentLoop" and w.started_at > ^threshold,
        select: count(w.id)
      )
      |> HermesBeam.Repo.one()

    (recent_runs || 0) == 0
  end

  defp next_concept(last_index) do
    index = rem(last_index, length(@concept_pool))
    concept = Enum.at(@concept_pool, index)
    {concept, index + 1}
  end

  defp default_agent_id do
    # Uses a stable deterministic UUID derived from the node name as the
    # synthetic data agent identity so all synthetics share one scratchpad.
    :crypto.hash(:md5, Atom.to_string(Node.self()))
    |> Base.encode16(case: :lower)
    |> then(fn hex ->
      <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4), e::binary-size(12)>> = String.slice(hex, 0, 32)
      "#{a}-#{b}-#{c}-#{d}-#{e}"
    end)
  end
end
