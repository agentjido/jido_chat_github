defmodule Jido.Chat.GitHub.AdapterTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.GitHub.Adapter

  defmodule FakeTransport do
    @behaviour Jido.Chat.GitHub.Transport

    def create_issue_comment("agentjido", "demo", 42, "hello", _opts),
      do:
        {:ok,
         %{
           "id" => 123,
           "body" => "hello",
           "created_at" => "2026-04-24T12:00:00Z",
           "html_url" => "https://github.test/comment"
         }}

    def update_issue_comment(_, _, _, body, _opts), do: {:ok, %{"id" => 123, "body" => body}}
    def delete_issue_comment(_, _, _, _opts), do: :ok
    def get_issue(_, _, _, _opts), do: {:ok, %{"id" => 9, "number" => 42, "title" => "Demo"}}

    def list_issue_comments(_, _, _, _opts),
      do: {:ok, [%{"id" => 123, "body" => "hello", "user" => %{"login" => "mike"}}]}

    def get_issue_comment(_, _, _, _opts),
      do: {:ok, %{"id" => 123, "body" => "hello", "user" => %{"login" => "mike"}}}
  end

  test "sends an issue comment" do
    assert {:ok, response} =
             Adapter.send_message("agentjido/demo#42", "hello", transport: FakeTransport)

    assert response.external_message_id == "123"
    assert response.external_room_id == "agentjido/demo#42"
  end

  test "normalizes issue comment webhooks" do
    payload = %{
      "action" => "created",
      "repository" => %{"name" => "demo", "owner" => %{"login" => "agentjido"}},
      "issue" => %{"id" => 9, "number" => 42, "title" => "Demo"},
      "comment" => %{"id" => 123, "body" => "hello", "user" => %{"id" => 1, "login" => "mike"}}
    }

    assert {:ok, incoming} = Adapter.transform_incoming(payload)
    assert incoming.external_room_id == "agentjido/demo#42"
    assert incoming.text == "hello"
  end
end
