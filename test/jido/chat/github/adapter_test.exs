defmodule Jido.Chat.GitHub.AdapterTest do
  use Jido.Chat.AdapterTestKit, adapter: Jido.Chat.GitHub.Adapter

  alias Jido.Chat.Client
  alias Jido.Chat.GitHub.Adapter
  alias Jido.Chat.Signal.{FetchMessage, Policy}

  defmodule FakeTransport do
    @behaviour Jido.Chat.GitHub.Transport

    def create_issue_comment(_owner, _repo, _number, body, _opts), do: {:ok, comment("1", body)}
    def update_issue_comment(_owner, _repo, id, body, _opts), do: {:ok, comment(id, body)}
    def delete_issue_comment(_owner, _repo, _id, _opts), do: :ok
    def get_issue_comment(_owner, _repo, id, _opts), do: {:ok, comment(id, "hello")}
    def list_issue_comments(_owner, _repo, _number, _opts), do: {:ok, [comment("1", "hello")]}
    def get_user(id, _opts), do: {:ok, %{"id" => id, "login" => "octocat", "name" => "Octo Cat"}}
    def create_issue(_, _, _, _, _), do: {:error, :unused}
    def get_issue(_, _, _, _), do: {:error, :unused}
    def list_issues(_, _, _), do: {:error, :unused}
    def create_issue_reaction(_, _, _, _, _), do: {:error, :unused}
    def create_issue_comment_reaction(_, _, _, _, _), do: {:error, :unused}
    def list_issue_reactions(_, _, _, _), do: {:error, :unused}
    def list_issue_comment_reactions(_, _, _, _), do: {:error, :unused}
    def delete_issue_reaction(_, _, _, _, _), do: {:error, :unused}
    def delete_issue_comment_reaction(_, _, _, _, _), do: {:error, :unused}

    defp comment(id, body) do
      %{
        "id" => id,
        "body" => body,
        "created_at" => "2026-01-01T00:00:00Z",
        "user" => %{"id" => "u1", "login" => "octocat"}
      }
    end
  end

  setup do
    %{client: Client.new!(Adapter, id: "github-test", transport: FakeTransport)}
  end

  test "runs the comment lifecycle through public Chat Actions", %{client: client} do
    assert {:ok, sent} = Jido.Chat.send_text(client, "agentjido/chat#1", "hello")
    assert sent.data["result"]["id"] == "1"

    assert {:ok, edited} = Jido.Chat.edit_message(client, "agentjido/chat#1", "1", "edited")
    assert edited.data["result"]["text"] == "edited"

    assert {:ok, fetched} = fetch_message(client, "agentjido/chat#1", "1")
    assert fetched.data["result"]["text"] == "hello"

    assert {:ok, deleted} = Jido.Chat.delete_message(client, "agentjido/chat#1", "1")
    assert deleted.data["result"] == %{"acknowledged" => true}
  end

  test "normalizes issue comment webhooks with stable identity", %{client: client} do
    payload = %{
      "action" => "created",
      "repository" => %{"full_name" => "agentjido/chat"},
      "issue" => %{"number" => 1, "title" => "Example"},
      "comment" => %{"id" => 9, "body" => "hello", "user" => %{"id" => 2, "login" => "octocat"}}
    }

    assert {:ok, first} = Jido.Chat.normalize(client, payload)
    assert {:ok, second} = Jido.Chat.normalize(client, payload)
    assert first.id == second.id
    assert [signal] = first.signals
    assert signal.data["room_id"] == "agentjido/chat#1"
    assert signal.data["message_id"] == "9"
  end

  defp fetch_message(client, room_id, message_id) do
    request =
      Policy.new!(FetchMessage, %{
        "client_id" => client.id,
        "request_id" => "github:fetch",
        "room_id" => room_id,
        "message_id" => message_id
      })

    Jido.Chat.execute(client, request)
  end
end
