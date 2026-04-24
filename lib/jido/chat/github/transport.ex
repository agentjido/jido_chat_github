defmodule Jido.Chat.GitHub.Transport do
  @moduledoc "Transport contract for GitHub REST API calls used by the adapter."

  @callback create_issue_comment(String.t(), String.t(), integer(), String.t(), keyword()) ::
              {:ok, map()} | {:error, term()}
  @callback update_issue_comment(
              String.t(),
              String.t(),
              integer() | String.t(),
              String.t(),
              keyword()
            ) ::
              {:ok, map()} | {:error, term()}
  @callback delete_issue_comment(String.t(), String.t(), integer() | String.t(), keyword()) ::
              :ok | {:error, term()}
  @callback get_issue(String.t(), String.t(), integer(), keyword()) ::
              {:ok, map()} | {:error, term()}
  @callback list_issue_comments(String.t(), String.t(), integer(), keyword()) ::
              {:ok, list(map())} | {:error, term()}
  @callback get_issue_comment(String.t(), String.t(), integer() | String.t(), keyword()) ::
              {:ok, map()} | {:error, term()}
end
