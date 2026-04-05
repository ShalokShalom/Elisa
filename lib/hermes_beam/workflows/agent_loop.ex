defmodule HermesBeam.Workflows.AgentLoop do
  @moduledoc """
  The core Reactor workflow implementing the Hermes BEAM agent cycle:

      Observe → Orient → Decide → Act → Reflect

  Each agent turn:
  1. Fetches semantically relevant memories from `Episodic` via pgvector.
     Degrades gracefully to an empty list if the index is not yet built or
     the embedding model is unavailable.
  2. Reads the current `Scratchpad` for bounded working context.
  3. Builds an enriched prompt (memories + scratchpad + user input).
  4. Routes to the correct hardware tier via `IntelligentRouter`.
     If the target model is in `:degraded` state, the step returns a
     clearly labelled degraded response rather than crashing the turn.
  5. Stores the interaction as an episodic reflection.
  6. Calls `tier_3_docs` to curate and persist an updated `Scratchpad`.
     Falls back to `:curation_skipped` on any failure so the turn always
     completes rather than rolling back.
  """
  use Reactor
  require Logger

  input :agent_id
  input :user_prompt
  input :task_type

  # ---------------------------------------------------------------------------
  # Step 1: Observe — load context
  # ---------------------------------------------------------------------------
  step :fetch_memories do
    argument :query,    input(:user_prompt)
    argument :agent_id, input(:agent_id)

    run fn %{query: query, agent_id: agent_id}, _ctx ->
      result =
        HermesBeam.Memory.Episodic
        |> Ash.Query.for_read(:recall_similar, %{query: query})
        |> Ash.Query.filter(agent_id == ^agent_id)
        |> Ash.read()

      case result do
        {:ok, memories} ->
          {:ok, memories}

        {:error, reason} ->
          Logger.warning("[AgentLoop] Episodic recall failed — continuing without memories: #{inspect(reason)}")
          {:ok, []}
      end
    end
  end

  step :fetch_scratchpad do
    argument :agent_id, input(:agent_id)

    run fn %{agent_id: agent_id}, _ctx ->
      # Use a read action filtered by agent_id rather than Ash.get/2 which
      # requires the primary key (UUID id), not agent_id.
      result =
        HermesBeam.Memory.Scratchpad
        |> Ash.Query.filter(agent_id == ^agent_id)
        |> Ash.read_one()

      case result do
        {:ok, pad} -> {:ok, pad}            # nil if no scratchpad exists yet
        {:error, reason} ->
          Logger.warning("[AgentLoop] Scratchpad read failed: #{inspect(reason)}")
          {:ok, nil}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Step 2: Orient — build the enriched prompt
  # ---------------------------------------------------------------------------
  step :build_context_prompt do
    argument :prompt,     input(:user_prompt)
    argument :memories,   result(:fetch_memories)
    argument :scratchpad, result(:fetch_scratchpad)

    run fn %{prompt: prompt, memories: memories, scratchpad: pad}, _ctx ->
      memory_section =
        memories
        |> Enum.map_join("\n", &"- #{&1.content}")
        |> case do
          ""   -> "No relevant past memories."
          text -> text
        end

      working_memory = if pad, do: pad.memory_text, else: "System initialized. No memories yet."
      user_profile   = if pad, do: pad.user_text,   else: "No user preferences recorded."

      enriched = """
      [Working Memory]
      #{working_memory}

      [User Profile]
      #{user_profile}

      [Relevant Past Memories]
      #{memory_section}

      [Current Request]
      #{prompt}
      """

      {:ok, enriched}
    end
  end

  # ---------------------------------------------------------------------------
  # Step 3: Decide and Act
  # ---------------------------------------------------------------------------
  step :execute_inference do
    argument :prompt,    result(:build_context_prompt)
    argument :task_type, input(:task_type)

    run fn %{prompt: prompt, task_type: task_type}, _ctx ->
      tier = HermesBeam.Workflows.IntelligentRouter.tier_for(task_type)

      case HermesBeam.LLM.ModelWorker.generate(tier, prompt) do
        {:ok, text} ->
          {:ok, text}

        {:error, :degraded} ->
          Logger.warning("[AgentLoop] Tier #{tier} is degraded — returning fallback response")
          {:ok, "[Model unavailable: #{tier} failed to load. Please check hardware and model config.]"}

        {:error, :loading} ->
          Logger.warning("[AgentLoop] Tier #{tier} is still loading — retrying is recommended")
          {:ok, "[Model loading: #{tier} is warming up. Please retry in a moment.]"}

        {:error, reason} ->
          Logger.error("[AgentLoop] Inference failed on #{tier}: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Step 4: Reflect — persist the interaction
  # ---------------------------------------------------------------------------
  step :store_reflection do
    argument :prompt,   input(:user_prompt)
    argument :response, result(:execute_inference)
    argument :agent_id, input(:agent_id)

    run fn %{prompt: prompt, response: response, agent_id: agent_id}, _ctx ->
      content = "User: #{prompt}\nAgent: #{response}"

      HermesBeam.Memory.Episodic
      |> Ash.Changeset.for_create(:store, %{
        agent_id: agent_id,
        content:  content,
        type:     :reflection
      })
      |> Ash.create()
    end
  end

  # ---------------------------------------------------------------------------
  # Step 5: Curate scratchpad — LLM condenses working memory
  # ---------------------------------------------------------------------------
  step :curate_scratchpad do
    argument :agent_id,   input(:agent_id)
    argument :scratchpad, result(:fetch_scratchpad)
    argument :prompt,     input(:user_prompt)
    argument :response,   result(:execute_inference)

    run fn %{agent_id: agent_id, scratchpad: pad, prompt: prompt, response: response}, _ctx ->
      # Skip curation if this was a degraded/loading fallback response.
      if String.starts_with?(response, "[Model") do
        {:ok, :curation_skipped}
      else
        current_memory = if pad, do: pad.memory_text, else: "System initialized. No memories yet."
        current_user   = if pad, do: pad.user_text,   else: "No user preferences recorded."

        curation_prompt = """
        You maintain two bounded memory fields for an AI agent.
        Update both fields to reflect the latest interaction.
        Keep only durable, high-value information.
        Hard limits: memory_text ≤ 2200 chars, user_text ≤ 1375 chars.

        Return ONLY valid JSON — no markdown, no explanation:
        {"memory_text":"...","user_text":"..."}

        Current memory_text:
        #{current_memory}

        Current user_text:
        #{current_user}

        Latest interaction:
        User: #{prompt}
        Agent: #{response}
        """

        with {:ok, raw} <- HermesBeam.LLM.ModelWorker.generate(:tier_3_docs, curation_prompt),
             cleaned    <- raw
                           |> String.replace(~r/```json\s*/i, "")
                           |> String.replace("```", "")
                           |> String.trim(),
             {:ok, attrs}       <- Jason.decode(cleaned),
             memory_text when is_binary(memory_text) <- Map.get(attrs, "memory_text"),
             user_text   when is_binary(user_text)   <- Map.get(attrs, "user_text") do
          if pad do
            pad
            |> Ash.Changeset.for_update(:curate_memory, %{memory_text: memory_text, user_text: user_text})
            |> Ash.update()
          else
            HermesBeam.Memory.Scratchpad
            |> Ash.Changeset.for_create(:initialize, %{
              agent_id:    agent_id,
              memory_text: memory_text,
              user_text:   user_text
            })
            |> Ash.create()
          end
        else
          {:error, reason} ->
            Logger.warning("[AgentLoop] Scratchpad curation failed: #{inspect(reason)}")
            {:ok, :curation_skipped}

          nil ->
            Logger.warning("[AgentLoop] Scratchpad curation returned incomplete JSON")
            {:ok, :curation_skipped}

          other ->
            Logger.warning("[AgentLoop] Scratchpad curation unexpected result: #{inspect(other)}")
            {:ok, :curation_skipped}
        end
      end
    end
  end
end
