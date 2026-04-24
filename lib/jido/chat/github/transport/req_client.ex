defmodule Jido.Chat.GitHub.Transport.ReqClient do
  @moduledoc "Req-backed GitHub REST transport."
  @behaviour Jido.Chat.GitHub.Transport

  @api_version "2026-03-10"

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
end
