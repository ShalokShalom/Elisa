defmodule HermesBeam.LLM.ModelWorker do
  @moduledoc """
  Loads a single Bumblebee model into EXLA (CUDA or Metal) and starts a
  distributed `Nx.Serving` under the tier's atom name.

  Once started, any node in the Erlang cluster can call:

      HermesBeam.LLM.ModelWorker.generate(:tier_1_reasoning, prompt)

  If the calling node does not host that serving, the BEAM VM will
  automatically forward the request to the node that does — entirely
  transparently and encrypted over the Tailscale tunnel.

  ## Failure handling

  Model loading can fail for reasons outside the app's control (wrong CUDA
  version, missing HuggingFace token, OOM). Rather than crashing and triggering
  infinite supervisor restarts, the worker moves into a `:degraded` state and
  responds to `generate/2` calls with `{:error, :degraded}` so callers can
  fall back gracefully.

  ## Degraded detection

  `generate/2` checks the worker's status via `GenServer.call/2` before
  attempting `Nx.Serving.batched_run/2`. This avoids masking `:noproc` and
  other infrastructure errors as `:degraded` when the process itself is gone.
  """
  use GenServer
  require Logger

  @max_tokens_per_tier %{
    tier_1_reasoning: 4096,
    tier_2_general:   2048,
    tier_3_docs:      1024
  }

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link({tier_name, hf_repo}) do
    GenServer.start_link(__MODULE__, {tier_name, hf_repo}, name: tier_name)
  end

  @doc """
  Generate text from the given prompt using the serving registered under
  `tier_name`. Routes automatically to the correct cluster node.

  Returns:
  - `{:ok, text}` on success
  - `{:error, :degraded}` if the model failed to load on the target node
  - `{:error, reason}` for unexpected infrastructure failures
  """
  @spec generate(atom(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def generate(tier_name, prompt) do
    # Ask the worker for its status before hitting the serving.
    # This gives a clean :degraded signal rather than an opaque :noproc exit.
    case GenServer.call(tier_name, :status) do
      :ready ->
        try do
          %{results: [%{text: text} | _]} = Nx.Serving.batched_run(tier_name, prompt)
          {:ok, text}
        catch
          :exit, reason -> {:error, reason}
        end

      :degraded ->
        {:error, :degraded}

      :loading ->
        # Still booting — treat as temporary unavailability
        {:error, :loading}
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init({tier_name, hf_repo}) do
    send(self(), {:load_model, tier_name, hf_repo})
    {:ok, %{tier: tier_name, repo: hf_repo, status: :loading}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, state.status, state}
  end

  @impl true
  def handle_info({:load_model, tier_name, hf_repo}, state) do
    Logger.info("[ModelWorker] Loading #{hf_repo} for tier #{tier_name}...")

    max_tokens = Map.get(@max_tokens_per_tier, tier_name, 2048)

    result =
      try do
        {:ok, model_info}        = Bumblebee.load_model({:hf, hf_repo}, type: :bf16, backend: EXLA.Backend)
        {:ok, tokenizer}         = Bumblebee.load_tokenizer({:hf, hf_repo})
        {:ok, generation_config} = Bumblebee.load_generation_config({:hf, hf_repo})

        generation_config =
          Bumblebee.configure(generation_config,
            max_new_tokens: max_tokens,
            strategy: %{type: :multinomial_sampling, top_p: 0.9}
          )

        serving =
          Bumblebee.Text.generation(model_info, tokenizer, generation_config,
            compile: [batch_size: 4, sequence_length: max_tokens],
            defn_options: [compiler: EXLA]
          )

        # Start the serving as a globally registered name so any cluster node
        # can call it. The serving runs in its own process tree — it is NOT
        # linked to this GenServer to avoid cascading failures.
        {:ok, _pid} =
          Nx.Serving.start_link(
            serving: serving,
            name: {:global, tier_name},
            batch_timeout: 100,
            partitions: true
          )

        :ok
      rescue
        e ->
          Logger.error("[ModelWorker] Failed to load #{hf_repo}: #{Exception.message(e)}")
          {:error, Exception.message(e)}
      catch
        kind, reason ->
          Logger.error("[ModelWorker] Unexpected #{kind} loading #{hf_repo}: #{inspect(reason)}")
          {:error, reason}
      end

    case result do
      :ok ->
        Logger.info("[ModelWorker] #{tier_name} ready")
        {:noreply, %{state | status: :ready}}

      {:error, reason} ->
        Logger.warning("[ModelWorker] #{tier_name} in degraded mode: #{inspect(reason)}")
        {:noreply, %{state | status: :degraded}}
    end
  end
end
