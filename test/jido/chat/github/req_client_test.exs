defmodule Jido.Chat.GitHub.Transport.ReqClientTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.GitHub.Transport.ReqClient

  defmodule RecordingAdapter do
    def run(request) do
      send(self(), {:req_client_request, request})
      {request, Process.get(:req_client_response)}
    end
  end

  setup do
    Process.put(:req_client_response, %Req.Response{status: 200, body: %{}})
    on_exit(fn -> Process.delete(:req_client_response) end)
  end

  test "creates a comment with private authentication and JSON" do
    respond(201, %{"id" => 7})

    assert {:ok, %{"id" => 7}} =
             ReqClient.create_issue_comment(
               "secret",
               "agentjido",
               "jido_chat",
               12,
               "hello",
               options()
             )

    request = request()
    assert request.method == :post
    assert request.url.path == "/repos/agentjido/jido_chat/issues/12/comments"
    assert Req.Request.get_header(request, "authorization") == ["Bearer secret"]
    assert Req.Request.get_header(request, "accept") == ["application/vnd.github+json"]
    assert Jason.decode!(IO.iodata_to_binary(request.body)) == %{"body" => "hello"}
  end

  test "updates, fetches, and deletes a comment" do
    respond(200, %{"id" => 9})

    assert {:ok, %{"id" => 9}} =
             ReqClient.update_issue_comment("secret", "owner", "repo", 9, "updated", options())

    assert request().url.path == "/repos/owner/repo/issues/comments/9"

    assert {:ok, %{"id" => 9}} =
             ReqClient.get_issue_comment("secret", "owner", "repo", 9, options())

    request = request()
    assert request.method == :get
    assert request.url.path == "/repos/owner/repo/issues/comments/9"

    respond(204, nil)
    assert :ok = ReqClient.delete_issue_comment("secret", "owner", "repo", 9, options())
    assert request().method == :delete
  end

  test "uses the correct user path for numeric IDs and logins" do
    assert {:ok, %{}} = ReqClient.get_user("secret", 42, options())
    assert request().url.path == "/user/42"

    assert {:ok, %{}} = ReqClient.get_user("secret", "octo cat", options())
    assert request().url.path == "/users/octo%20cat"

    assert {:ok, %{}} = ReqClient.get_user("secret", :octocat, options())
    assert request().url.path == "/users/octocat"
  end

  test "bounds comment pagination and keeps the page" do
    assert {:ok, %{}} =
             ReqClient.list_issue_comments(
               "secret",
               "owner",
               "repo",
               4,
               Keyword.merge(options(), per_page: 500, page: 3)
             )

    request = request()
    assert request.url.path == "/repos/owner/repo/issues/4/comments"
    assert URI.decode_query(request.url.query) == %{"page" => "3", "per_page" => "100"}

    assert {:ok, %{}} =
             ReqClient.list_issue_comments("secret", "owner", "repo", 4, options())

    assert request().url.query == nil
  end

  test "returns provider and transport errors" do
    respond(422, %{"message" => "invalid"})

    assert {:error, {:github_api_error, 422, %{"message" => "invalid"}}} =
             ReqClient.get_issue_comment("secret", "owner", "repo", 9, options())

    request()

    assert {:error, {:github_api_error, 422, %{"message" => "invalid"}}} =
             ReqClient.delete_issue_comment("secret", "owner", "repo", 9, options())

    request()
    Process.put(:req_client_response, %Req.TransportError{reason: :timeout})

    assert {:error, %Req.TransportError{reason: :timeout}} =
             ReqClient.get_issue_comment("secret", "owner", "repo", 9, options())

    request()
  end

  defp options do
    [base_url: "https://api.github.test", req_adapter: RecordingAdapter]
  end

  defp respond(status, body) do
    Process.put(:req_client_response, %Req.Response{status: status, body: body})
  end

  defp request do
    assert_receive {:req_client_request, request}
    request
  end
end
