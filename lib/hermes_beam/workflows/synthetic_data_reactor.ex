defmodule HermesBeam.Workflows.SyntheticDataReactor do
  @moduledoc """
  Reactor workflow that generates synthetic episodic memories for a given
  concept during idle periods, improving the agent's recall quality over time.

  Steps:
    1. Build a structured prompt asking the LLM for 3 realistic scenarios.
    2. Route the prompt to :tier_2_general (Llama 3 8B) — fast, capable enough.
    3. Parse the JSON response into individual scenario strings.
    4. Batch-store each scenario as an Episodic memory with type :synthetic.

  The workflow is triggered by `HermesBeam.IdleScheduler` when the cluster
  is idle, or manually via the Livebook dashboard (Section 5).
  """
  use Reactor
  require Logger

  input :concept_to_explore
  input :agent_id

  # ---------------------------------------------------------------------------
  # Step 1: Build the generation prompt
  # ---------------------------------------------------------------------------
  step :build_prompt do
    argument :concept, input(:concept_to_explore)

    run fn %{concept: concept}, _ctx ->
      prompt = """
      You are a synthetic training data generator for an AI agent.

      Generate exactly 3 realistic, distinct scenarios that would help an AI
      agent deeply understand the following concept:

      CONCEPT: #{concept}

      Respond ONLY with a valid JSON array of 3 strings, each describing one
      scenario in 2-4 sentences. No preamble, no explanation, just the JSON.

      Example format:
      ["Scenario one description here.", "Scenario two here.", "Scenario three."]
      """

      {:ok, prompt}
    end
  end

  # ---------------------------------------------------------------------------
  # Step 2: Generate via LLM
  # ---------------------------------------------------------------------------
  step :generate_scenarios do
    argument :prompt, result(:build_prompt)

    run fn %{prompt: prompt}, _ctx ->
      Logger.info("[SyntheticDataReactor] Generating scenarios via :tier_2_general")
      HermesBeam.LLM.ModelWorker.generate(:tier_2_general, prompt)
    end
  end

  # ---------------------------------------------------------------------------
  # Step 3: Parse JSON response
  # ---------------------------------------------------------------------------
  step :parse_scenarios do
    argument :raw, result(:generate_scenarios)

    run fn %{raw: raw}, _ctx ->
      cleaned =
        raw
        |> String.replace(~r/```json\s*/i, "")
        |> String.replace(~r/```/, "")
        |> String.trim()

      case Jason.decode(cleaned) do
        {:ok, scenarios} when is_list(scenarios) ->
          string_scenarios = Enum.filter(scenarios, &is_binary/1)

          if length(string_scenarios) == 0 do
            {:error, "LLM returned JSON but no string scenarios: #{inspect(scenarios)}"}
          else
            {:ok, string_scenarios}
          end

        {:ok, other} ->
          {:error, "Expected JSON array, got: #{inspect(other)}"}

        {:error, reason} ->
          Logger.warning("[SyntheticDataReactor] JSON parse failed: #{inspect(reason)}. Raw: #{String.slice(raw, 0, 200)}")
          {:error, "JSON parse failed: #{inspect(reason)}"}
      end
    end

    compensate fn _reason, _inputs, _ctx ->
      Logger.warning("[SyntheticDataReactor] Scenario parse failed — skipping batch")
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Step 4: Store each scenario as an Episodic memory
  # ---------------------------------------------------------------------------
  step :store_scenarios do
    argument :scenarios, result(:parse_scenarios)
    argument :concept,   input(:concept_to_explore)
    argument :agent_id,  input(:agent_id)

    run fn %{scenarios: scenarios, concept: concept, agent_id: agent_id}, _ctx ->
      results =
        Enum.map(scenarios, fn scenario ->
          content = "[Synthetic | #{concept}] #{scenario}"

          HermesBeam.Memory.Episodic
          |> Ash.Changeset.for_create(:store, %{
            agent_id: agent_id,
            content:  content,
            type:     :synthetic
          })
          |> Ash.create()
        end)

      errors = Enum.filter(results, &match?({:error, _}, &1))
      stored = Enum.count(results, &match?({:ok, _}, &1))

      :telemetry.execute(
        [:hermes_beam, :synthetic, :generated],
        %{count: stored},
        %{concept: concept, errors: length(errors)}
      )

      Logger.info("[SyntheticDataReactor] Stored #{stored} synthetic memories for '#{concept}'")

      if length(errors) > 0 do
        Logger.warning("[SyntheticDataReactor] #{length(errors)} store errors: #{inspect(errors)}")
      end

      {:ok, %{stored: stored, errors: length(errors)}}
    end
  end
end
