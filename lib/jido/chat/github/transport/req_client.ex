defmodule Jido.Chat.GitHub.Transport.ReqClient do
  @moduledoc "Req-backed GitHub REST transport."
  @behaviour Jido.Chat.GitHub.Transport

  @api_version "2026-03-10"

  @impl true
  def create_issue(owner, repo, title, body, opts) do
    request(:post, "/repos/#{owner}/#{repo}/issues", opts,
      json: issue_create_body(title, body, opts)
    )
  end

  @impl true
  def create_issue_comment(owner, repo, issue_number, body, opts) do
    request(:post, "/repos/#{owner}/#{repo}/issues/#{issue_number}/comments", opts,
      json: %{body: body}
    )
  end

  @impl true
  def update_issue_comment(owner, repo, comment_id, body, opts) do
    request(:patch, "/repos/#{owner}/#{repo}/issues/comments/#{comment_id}", opts,
      json: %{body: body}
    )
  end

  @impl true
  def delete_issue_comment(owner, repo, comment_id, opts) do
    case request(:delete, "/repos/#{owner}/#{repo}/issues/comments/#{comment_id}", opts) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  @impl true
  def get_issue(owner, repo, issue_number, opts) do
    request(:get, "/repos/#{owner}/#{repo}/issues/#{issue_number}", opts)
  end

  @impl true
  def list_issue_comments(owner, repo, issue_number, opts) do
    request(:get, "/repos/#{owner}/#{repo}/issues/#{issue_number}/comments", opts)
  end

  @impl true
  def get_issue_comment(owner, repo, comment_id, opts) do
    request(:get, "/repos/#{owner}/#{repo}/issues/comments/#{comment_id}", opts)
  end

  @impl true
  def list_issues(owner, repo, opts) do
    request(:get, "/repos/#{owner}/#{repo}/issues", opts, params: issue_list_params(opts))
  end

  @impl true
  def create_issue_reaction(owner, repo, issue_number, content, opts) do
    request(:post, "/repos/#{owner}/#{repo}/issues/#{issue_number}/reactions", opts,
      json: %{content: content}
    )
  end

  @impl true
  def create_issue_comment_reaction(owner, repo, comment_id, content, opts) do
    request(:post, "/repos/#{owner}/#{repo}/issues/comments/#{comment_id}/reactions", opts,
      json: %{content: content}
    )
  end

  @impl true
  def list_issue_reactions(owner, repo, issue_number, opts) do
    request(:get, "/repos/#{owner}/#{repo}/issues/#{issue_number}/reactions", opts)
  end

  @impl true
  def list_issue_comment_reactions(owner, repo, comment_id, opts) do
    request(:get, "/repos/#{owner}/#{repo}/issues/comments/#{comment_id}/reactions", opts)
  end

  @impl true
  def delete_issue_reaction(owner, repo, issue_number, reaction_id, opts) do
    case request(
           :delete,
           "/repos/#{owner}/#{repo}/issues/#{issue_number}/reactions/#{reaction_id}",
           opts
         ) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  @impl true
  def delete_issue_comment_reaction(owner, repo, comment_id, reaction_id, opts) do
    case request(
           :delete,
           "/repos/#{owner}/#{repo}/issues/comments/#{comment_id}/reactions/#{reaction_id}",
           opts
         ) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  defp request(method, path, opts, req_opts \\ []) do
    token = Keyword.get(opts, :token) || System.get_env("GITHUB_TOKEN")
    base_url = Keyword.get(opts, :base_url, "https://api.github.com")

    headers = [
      {"accept", "application/vnd.github+json"},
      {"x-github-api-version", @api_version}
    ]

    headers =
      if token in [nil, ""], do: headers, else: [{"authorization", "Bearer #{token}"} | headers]

    [method: method, url: base_url <> path, headers: headers]
    |> Keyword.merge(req_opts)
    |> Req.request()
    |> case do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body || %{}}
      {:ok, %{status: status, body: body}} -> {:error, {:github_api_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp issue_list_params(opts) do
    []
    |> maybe_param(:state, Keyword.get(opts, :state, "open"))
    |> maybe_param(:per_page, Keyword.get(opts, :limit, Keyword.get(opts, :per_page)))
    |> maybe_param(:page, Keyword.get(opts, :page))
    |> maybe_param(:since, Keyword.get(opts, :since))
    |> maybe_param(:labels, Keyword.get(opts, :labels))
    |> maybe_param(:sort, Keyword.get(opts, :sort))
    |> maybe_param(:direction, Keyword.get(opts, :direction))
  end

  defp issue_create_body(title, body, opts) do
    %{title: title}
    |> maybe_json(:body, body)
    |> maybe_json(:labels, Keyword.get(opts, :labels))
    |> maybe_json(:assignees, Keyword.get(opts, :assignees))
    |> maybe_json(:milestone, Keyword.get(opts, :milestone))
  end

  defp maybe_json(body, _key, value) when value in [nil, "", []], do: body
  defp maybe_json(body, key, value), do: Map.put(body, key, value)

  defp maybe_param(params, _key, value) when value in [nil, ""], do: params
  defp maybe_param(params, key, value), do: Keyword.put(params, key, value)
end
