defmodule Jido.Chat.GitHub.Transport do
  @moduledoc "Transport contract for GitHub REST API calls used by the adapter."

  @callback create_issue_comment(String.t(), String.t(), integer(), String.t(), keyword()) ::
              {:ok, map()} | {:error, term()}
  @callback create_issue(String.t(), String.t(), String.t(), String.t() | nil, keyword()) ::
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
  @callback list_issues(String.t(), String.t(), keyword()) ::
              {:ok, list(map())} | {:error, term()}
  @callback create_issue_reaction(String.t(), String.t(), integer(), String.t(), keyword()) ::
              {:ok, map()} | {:error, term()}
  @callback create_issue_comment_reaction(
              String.t(),
              String.t(),
              integer() | String.t(),
              String.t(),
              keyword()
            ) ::
              {:ok, map()} | {:error, term()}
  @callback list_issue_reactions(String.t(), String.t(), integer(), keyword()) ::
              {:ok, list(map())} | {:error, term()}
  @callback list_issue_comment_reactions(
              String.t(),
              String.t(),
              integer() | String.t(),
              keyword()
            ) ::
              {:ok, list(map())} | {:error, term()}
  @callback delete_issue_reaction(
              String.t(),
              String.t(),
              integer(),
              integer() | String.t(),
              keyword()
            ) ::
              :ok | {:error, term()}
  @callback delete_issue_comment_reaction(
              String.t(),
              String.t(),
              integer() | String.t(),
              integer() | String.t(),
              keyword()
            ) ::
              :ok | {:error, term()}
end
