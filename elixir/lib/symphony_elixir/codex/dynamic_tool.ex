defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.{Config, Linear.Issue}
  alias SymphonyElixir.Linear.Client

  alias SymphonyElixir.Tracker.{
    EconomicOS,
    EconomicOSMiniPRReview,
    EconomicOSTelegramWorkItem
  }

  @linear_graphql_tool "linear_graphql"
  @linear_graphql_description """
  Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.
  """
  @linear_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }
  @economic_os_submit_tool "economic_os_submit_analysis"
  @economic_os_submit_description """
  Submit the cited analysis for the current Economic OS agenda. The agenda id
  is bound by Symphony and cannot be selected by the model.
  """
  @economic_os_submit_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["response", "response_data", "outcome"],
    "properties" => %{
      "response" => %{
        "type" => "string",
        "minLength" => 1,
        "description" => "Concise natural-language result with explicit source citations."
      },
      "response_data" => %{
        "type" => "object",
        "description" => "Structured result required by the agenda response contracts.",
        "additionalProperties" => true
      },
      "outcome" => %{
        "type" => "string",
        "enum" => ["answered", "needs_revision"],
        "description" => "Answer a complete agenda or keep an insufficient manager response open."
      }
    }
  }
  @mini_pr_review_submit_tool "economic_os_submit_mini_pr_review"
  @mini_pr_review_submit_description """
  Submit the typed result for the current immutable Mini pull-request review.
  Review identity, repository and pull number are bound by Symphony and cannot
  be selected by the model. This tool cannot publish or merge.
  """
  @mini_pr_review_finding_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => [
      "id",
      "severity",
      "confidence",
      "title",
      "evidence",
      "violated_contract",
      "impact",
      "remediation",
      "verification"
    ],
    "properties" => %{
      "id" => %{"type" => "string", "pattern" => "^F-[0-9]{3}$"},
      "severity" => %{"type" => "string", "enum" => ["blocking", "important", "suggestion"]},
      "confidence" => %{"type" => "number", "minimum" => 0, "maximum" => 1},
      "title" => %{"type" => "string", "minLength" => 1},
      "evidence" => %{"type" => "string", "minLength" => 1},
      "violated_contract" => %{"type" => "string", "minLength" => 1},
      "impact" => %{"type" => "string", "minLength" => 1},
      "remediation" => %{"type" => "string", "minLength" => 1},
      "verification" => %{"type" => "string", "minLength" => 1},
      "path" => %{"type" => ["string", "null"]},
      "line" => %{"type" => ["integer", "null"], "minimum" => 1},
      "side" => %{"type" => ["string", "null"], "enum" => ["LEFT", "RIGHT", nil]}
    }
  }
  @mini_pr_review_submit_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => [
      "schema_version",
      "head_sha",
      "policy_revision",
      "policy_digest",
      "manifest_digest",
      "verdict",
      "summary",
      "checked_areas",
      "reusable_assessment",
      "placement_assessment",
      "evidence",
      "findings",
      "complete"
    ],
    "properties" => %{
      "schema_version" => %{"type" => "string", "enum" => ["mini-pr-review-result-v1"]},
      "head_sha" => %{"type" => "string", "pattern" => "^[0-9a-f]{40}$"},
      "policy_revision" => %{"type" => "string", "minLength" => 1},
      "policy_digest" => %{"type" => "string", "pattern" => "^[0-9a-f]{64}$"},
      "manifest_digest" => %{"type" => "string", "pattern" => "^[0-9a-f]{64}$"},
      "verdict" => %{"type" => "string", "enum" => ["approve", "request_changes"]},
      "summary" => %{"type" => "string", "minLength" => 1},
      "checked_areas" => %{"type" => "array", "minItems" => 1, "items" => %{"type" => "string"}},
      "reusable_assessment" => %{"type" => "string", "minLength" => 1},
      "placement_assessment" => %{"type" => "string", "minLength" => 1},
      "evidence" => %{"type" => "array", "minItems" => 1, "items" => %{"type" => "string"}},
      "findings" => %{"type" => "array", "items" => @mini_pr_review_finding_schema},
      "complete" => %{"type" => "boolean"}
    }
  }
  @telegram_work_item_submit_tool "economic_os_submit_telegram_work_item"
  @telegram_work_item_submit_description """
  Submit the typed result for the current Telegram work item. Symphony binds
  the work-item identity; the model cannot select a work item or recipient.
  """
  @telegram_interaction_schema %{
    "type" => ["object", "null"],
    "additionalProperties" => false,
    "required" => [
      "kind",
      "text",
      "reason",
      "unlocks",
      "proposal_digest",
      "allowed_answers",
      "boundary_operation",
      "deadline"
    ],
    "properties" => %{
      "kind" => %{"type" => "string", "enum" => ["approval", "choice", "question"]},
      "text" => %{"type" => "string", "minLength" => 1},
      "reason" => %{"type" => "string", "minLength" => 1},
      "unlocks" => %{"type" => "string", "minLength" => 1},
      "proposal_digest" => %{"type" => "string", "pattern" => "^[0-9a-f]{64}$"},
      "allowed_answers" => %{
        "type" => "array",
        "minItems" => 1,
        "maxItems" => 8,
        "items" => %{"type" => "string"}
      },
      "boundary_operation" => %{"type" => ["string", "null"]},
      "deadline" => %{"type" => ["string", "null"], "format" => "date-time"}
    }
  }
  @telegram_work_item_submit_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => [
      "schema_version",
      "manifest_digest",
      "outcome",
      "summary",
      "artifact_refs",
      "evidence_refs",
      "interaction"
    ],
    "properties" => %{
      "schema_version" => %{"type" => "string", "enum" => ["telegram-work-item-result-v1"]},
      "manifest_digest" => %{"type" => "string", "pattern" => "^[0-9a-f]{64}$"},
      "outcome" => %{"type" => "string", "enum" => ["completed", "failed", "awaiting_human"]},
      "summary" => %{"type" => "string", "minLength" => 1},
      "artifact_refs" => %{"type" => "array", "items" => %{"type" => "string"}},
      "evidence_refs" => %{"type" => "array", "items" => %{"type" => "string"}},
      "interaction" => @telegram_interaction_schema
    }
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @linear_graphql_tool ->
        execute_linear_graphql(arguments, opts)

      @economic_os_submit_tool ->
        execute_economic_os_submit(arguments, opts)

      @mini_pr_review_submit_tool ->
        execute_mini_pr_review_submit(arguments, opts)

      @telegram_work_item_submit_tool ->
        execute_telegram_work_item_submit(arguments, opts)

      other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names()
          }
        })
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    case Config.tracker_kind() do
      "economic_os" ->
        [
          %{
            "name" => @economic_os_submit_tool,
            "description" => @economic_os_submit_description,
            "inputSchema" => @economic_os_submit_input_schema
          }
        ]

      "economic_os_mini_pr_review" ->
        [
          %{
            "name" => @mini_pr_review_submit_tool,
            "description" => @mini_pr_review_submit_description,
            "inputSchema" => @mini_pr_review_submit_input_schema
          }
        ]

      "economic_os_telegram_work_item" ->
        [
          %{
            "name" => @telegram_work_item_submit_tool,
            "description" => @telegram_work_item_submit_description,
            "inputSchema" => @telegram_work_item_submit_input_schema
          }
        ]

      _ ->
        [
          %{
            "name" => @linear_graphql_tool,
            "description" => @linear_graphql_description,
            "inputSchema" => @linear_graphql_input_schema
          }
        ]
    end
  end

  defp execute_economic_os_submit(arguments, opts) do
    submitter = Keyword.get(opts, :economic_os_submitter, &EconomicOS.submit_analysis/4)

    with {:ok, issue_id} <- current_issue_id(Keyword.get(opts, :issue)),
         {:ok, response, response_data, outcome} <- normalize_economic_os_submit(arguments),
         :ok <- submitter.(issue_id, response, response_data, outcome) do
      graphql_response(%{"agendaId" => issue_id, "outcome" => outcome})
    else
      {:error, reason} -> failure_response(economic_os_tool_error_payload(reason))
    end
  end

  defp execute_mini_pr_review_submit(arguments, opts) do
    submitter =
      Keyword.get(opts, :mini_pr_review_submitter, &EconomicOSMiniPRReview.submit_review/2)

    with {:ok, issue_id} <- current_issue_id(Keyword.get(opts, :issue)),
         {:ok, result} <- normalize_mini_pr_review_submit(arguments),
         :ok <- submitter.(issue_id, result) do
      graphql_response(%{"reviewId" => issue_id, "verdict" => field(result, "verdict")})
    else
      {:error, reason} -> failure_response(mini_pr_review_tool_error_payload(reason))
    end
  end

  defp execute_telegram_work_item_submit(arguments, opts) do
    submitter =
      Keyword.get(
        opts,
        :telegram_work_item_submitter,
        &EconomicOSTelegramWorkItem.submit_result/2
      )

    with {:ok, issue_id} <- current_issue_id(Keyword.get(opts, :issue)),
         {:ok, result} <- normalize_telegram_work_item_submit(arguments),
         :ok <- submitter.(issue_id, result) do
      graphql_response(%{
        "workItemId" => issue_id,
        "outcome" => field(result, "outcome")
      })
    else
      {:error, reason} -> failure_response(telegram_work_item_tool_error_payload(reason))
    end
  end

  defp normalize_telegram_work_item_submit(arguments) when is_map(arguments) do
    forbidden = [
      "work_item_id",
      :work_item_id,
      "recipient_person_id",
      :recipient_person_id,
      "chat_id",
      :chat_id
    ]

    required =
      Enum.reject(@telegram_work_item_submit_input_schema["required"], &has_field?(arguments, &1))

    outcome = field(arguments, "outcome")
    interaction = field(arguments, "interaction")

    cond do
      Enum.any?(forbidden, &Map.has_key?(arguments, &1)) ->
        {:error, :model_supplied_work_item_identity}

      required != [] ->
        {:error, {:missing_work_item_fields, required}}

      outcome not in ["completed", "failed", "awaiting_human"] ->
        {:error, :invalid_work_item_outcome}

      outcome == "awaiting_human" and not is_map(interaction) ->
        {:error, :missing_human_interaction}

      outcome != "awaiting_human" and not is_nil(interaction) ->
        {:error, :unexpected_human_interaction}

      true ->
        {:ok, arguments}
    end
  end

  defp normalize_telegram_work_item_submit(_arguments),
    do: {:error, :invalid_work_item_arguments}

  defp normalize_mini_pr_review_submit(arguments) when is_map(arguments) do
    forbidden = ["review_id", :review_id, "repository", :repository, "pull_number", :pull_number]
    required = Enum.reject(@mini_pr_review_submit_input_schema["required"], &has_field?(arguments, &1))

    cond do
      Enum.any?(forbidden, &Map.has_key?(arguments, &1)) ->
        {:error, :model_supplied_review_identity}

      required != [] ->
        {:error, {:missing_review_fields, required}}

      field(arguments, "verdict") not in ["approve", "request_changes"] ->
        {:error, :invalid_review_verdict}

      not is_list(field(arguments, "findings")) ->
        {:error, :invalid_review_findings}

      true ->
        {:ok, arguments}
    end
  end

  defp normalize_mini_pr_review_submit(_arguments), do: {:error, :invalid_review_arguments}

  defp current_issue_id(%Issue{id: issue_id}) when is_binary(issue_id), do: {:ok, issue_id}
  defp current_issue_id(%{id: issue_id}) when is_binary(issue_id), do: {:ok, issue_id}
  defp current_issue_id(_issue), do: {:error, :missing_current_agenda}

  defp normalize_economic_os_submit(arguments) when is_map(arguments) do
    response = Map.get(arguments, "response") || Map.get(arguments, :response)
    response_data = Map.get(arguments, "response_data") || Map.get(arguments, :response_data)
    outcome = Map.get(arguments, "outcome") || Map.get(arguments, :outcome)

    cond do
      not is_binary(response) or String.trim(response) == "" ->
        {:error, :invalid_analysis_response}

      not is_map(response_data) ->
        {:error, :invalid_analysis_response_data}

      outcome not in ["answered", "needs_revision"] ->
        {:error, :invalid_analysis_outcome}

      true ->
        {:ok, String.trim(response), response_data, outcome}
    end
  end

  defp normalize_economic_os_submit(_arguments), do: {:error, :invalid_analysis_arguments}

  defp execute_linear_graphql(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    with {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         {:ok, response} <- linear_client.(query, variables, []) do
      graphql_response(response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_map(arguments) do
    case normalize_query(arguments) do
      {:ok, query} ->
        case normalize_variables(arguments) do
          {:ok, variables} ->
            {:ok, query, variables}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_linear_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp graphql_response(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    %{
      "success" => success,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => encode_payload(response)
        }
      ]
    }
  end

  defp failure_response(payload) do
    %{
      "success" => false,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => encode_payload(payload)
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp tool_error_payload(:missing_query) do
    %{
      "error" => %{
        "message" => "`linear_graphql` requires a non-empty `query` string."
      }
    }
  end

  defp tool_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  defp tool_error_payload(:invalid_variables) do
    %{
      "error" => %{
        "message" => "`linear_graphql.variables` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:missing_linear_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
      }
    }
  end

  defp tool_error_payload({:linear_api_status, status}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:linear_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "Linear GraphQL tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp economic_os_tool_error_payload({:economic_os_api_status, status, response_body}) do
    %{
      "error" => %{
        "message" => "Economic OS analysis submission failed with HTTP #{status}.",
        "status" => status,
        "details" => response_body
      }
    }
  end

  defp economic_os_tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "Economic OS analysis submission failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp mini_pr_review_tool_error_payload({:economic_os_api_status, status, response_body}) do
    %{
      "error" => %{
        "message" => "Mini PR review submission failed with HTTP #{status}.",
        "status" => status,
        "details" => response_body
      }
    }
  end

  defp mini_pr_review_tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "Mini PR review submission failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp telegram_work_item_tool_error_payload({:economic_os_api_status, status, response_body}) do
    %{
      "error" => %{
        "message" => "Telegram work-item submission failed with HTTP #{status}.",
        "status" => status,
        "details" => response_body
      }
    }
  end

  defp telegram_work_item_tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "Telegram work-item submission failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp field(map, key), do: Map.get(map, key) || Map.get(map, String.to_atom(key))
  defp has_field?(map, key), do: Map.has_key?(map, key) or Map.has_key?(map, String.to_atom(key))

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end
end
