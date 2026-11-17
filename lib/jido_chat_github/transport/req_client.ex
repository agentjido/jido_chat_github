defmodule Jido.Chat.GitHub.Transport.ReqClient do
  @moduledoc "Req-backed GitHub REST transport."
  @behaviour Jido.Chat.GitHub.Transport

  @api_version "2026-03-10"
  @max_comment_page_size 100

  @impl true
  def create_issue_comment(token, owner, repo, issue_number, body, opts) do
    request(token, :post, "/repos/#{owner}/#{repo}/issues/#{issue_number}/comments", opts,
      json: %{body: body}
    )
  end

  @impl true
  def update_issue_comment(token, owner, repo, comment_id, body, opts) do
    request(token, :patch, "/repos/#{owner}/#{repo}/issues/comments/#{comment_id}", opts,
      json: %{body: body}
    )
  end

  @impl true
  def delete_issue_comment(token, owner, repo, comment_id, opts) do
    case request(token, :delete, "/repos/#{owner}/#{repo}/issues/comments/#{comment_id}", opts) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  @impl true
  def get_user(token, user_id, opts) do
    request(token, :get, github_user_path(user_id), opts)
  end

  @impl true
  def list_issue_comments(token, owner, repo, issue_number, opts) do
    request(token, :get, "/repos/#{owner}/#{repo}/issues/#{issue_number}/comments", opts,
      params: comment_list_params(opts)
    )
  end

  @impl true
  def get_issue_comment(token, owner, repo, comment_id, opts) do
    request(token, :get, "/repos/#{owner}/#{repo}/issues/comments/#{comment_id}", opts)
  end

  defp request(token, method, path, opts, req_opts \\ []) do
    base_url = Keyword.get(opts, :base_url, "https://api.github.com")

    headers = [
      {"accept", "application/vnd.github+json"},
      {"x-github-api-version", @api_version}
    ]

    headers = [{"authorization", "Bearer #{token}"} | headers]

    transport_opts =
      case Keyword.get(opts, :req_adapter) do
        adapter when is_atom(adapter) -> [adapter: adapter]
        _ -> []
      end

    [method: method, url: base_url <> path, headers: headers, retry: false]
    |> Keyword.merge(transport_opts)
    |> Keyword.merge(req_opts)
    |> Req.request()
    |> case do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body || %{}}
      {:ok, %{status: status, body: body}} -> {:error, {:github_api_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp github_user_path(user_id) do
    path = if numeric_github_user_id?(user_id), do: "/user/", else: "/users/"
    path <> URI.encode(to_string(user_id))
  end

  defp numeric_github_user_id?(user_id) when is_integer(user_id), do: true
  defp numeric_github_user_id?(user_id) when is_binary(user_id), do: user_id =~ ~r/^\d+$/
  defp numeric_github_user_id?(_user_id), do: false

  defp comment_list_params(opts) do
    []
    |> maybe_param(:per_page, bounded_comment_page_size(Keyword.get(opts, :per_page)))
    |> maybe_param(:page, Keyword.get(opts, :page))
  end

  defp bounded_comment_page_size(per_page) when is_integer(per_page),
    do: per_page |> max(1) |> min(@max_comment_page_size)

  defp bounded_comment_page_size(per_page), do: per_page

  defp maybe_param(params, _key, value) when value in [nil, ""], do: params
  defp maybe_param(params, key, value), do: Keyword.put(params, key, value)
end
