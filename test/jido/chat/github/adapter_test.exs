defmodule Jido.Chat.GitHub.AdapterTest do
  use Jido.Chat.AdapterTestKit, adapter: Jido.Chat.GitHub.Adapter

  alias Jido.Chat.Client
  alias Jido.Chat.GitHub
  alias Jido.Chat.GitHub.{Adapter, Operations}

  alias Jido.Chat.Signal.{
    FetchMessage,
    FetchMessages,
    GetUser,
    MessageReceived,
    MessageUpdated,
    NormalizationFailed,
    Policy
  }

  defmodule FakeTransport do
    @behaviour Jido.Chat.GitHub.Transport

    def create_issue_comment(token, _owner, _repo, _number, body, opts) do
      if observer = opts[:observer], do: send(observer, {:github_transport, token, opts})
      {:ok, comment("1", body)}
    end

    def update_issue_comment(_token, _owner, _repo, id, body, _opts),
      do: {:ok, comment(id, body)}

    def delete_issue_comment(_token, _owner, _repo, _id, _opts), do: :ok

    def get_issue_comment(_token, _owner, _repo, id, opts) do
      case opts[:provider_result] do
        :invalid -> {:ok, :invalid}
        :missing_id -> {:ok, %{}}
        _ -> {:ok, comment(id, "hello")}
      end
    end

    def list_issue_comments(_token, _owner, _repo, _number, opts) do
      case opts[:provider_result] do
        :invalid -> {:ok, :invalid}
        :mixed -> {:ok, [comment("1", "hello"), :invalid]}
        _ -> {:ok, [comment("1", "hello")]}
      end
    end

    def get_user(_token, id, _opts),
      do: {:ok, %{"id" => id, "login" => "octocat", "name" => "Octo Cat"}}

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
    %{
      client:
        Client.new!(Adapter,
          id: "github-test",
          credentials: %{token: "test-secret"},
          transport: FakeTransport
        )
    }
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

  test "passes credentials separately from adapter config", %{client: client} do
    client = %{client | config: [observer: self(), marker: :kept]}

    assert {:ok, _} = Jido.Chat.send_text(client, "agentjido/chat#1", "hello")
    assert_receive {:github_transport, "test-secret", opts}
    assert opts[:marker] == :kept
    refute Keyword.has_key?(opts, :token)
    refute Keyword.has_key?(opts, :credentials)
  end

  test "fetches a message page and a normalized user", %{client: client} do
    messages =
      execute(client, FetchMessages, %{
        "room_id" => "agentjido/chat#1",
        "limit" => 1,
        "cursor" => "2"
      })

    assert {:ok, page} = messages
    assert page.data["result"]["complete"] == false
    assert page.data["result"]["next_cursor"] == "3"
    assert [%{"id" => "1", "text" => "hello"}] = page.data["result"]["messages"]

    assert {:ok, user} = execute(client, GetUser, %{"user_id" => "42"})

    assert user.data["result"] == %{
             "id" => "42",
             "username" => "octocat",
             "display_name" => "Octo Cat"
           }
  end

  test "rejects invalid operation input before transport I/O", %{client: client} do
    assert {:error, :invalid_room_id} =
             Operations.invoke(
               :send_message,
               client,
               %{data: %{"room_id" => "invalid", "text" => "hello"}},
               []
             )

    assert {:error, :invalid_query_cursor} =
             Operations.invoke(
               :fetch_messages,
               client,
               %{data: %{"room_id" => "agentjido/chat#1", "cursor" => "zero"}},
               []
             )

    assert {:error, :invalid_room_id} =
             Operations.invoke(:send_message, client, %{data: %{"room_id" => nil}}, [])

    assert {:error, {:not_attempted, :unsupported}} =
             Operations.invoke(:unknown, client, %{data: %{}}, [])

    assert {:error, {:not_attempted, :unsupported}} =
             Operations.invoke(:send_message, :invalid_client, %{data: %{}}, [])
  end

  test "rejects invalid provider results", %{client: client} do
    request = %{data: %{"room_id" => "agentjido/chat#1", "message_id" => "1"}}

    assert {:error, :invalid_provider_result} =
             Operations.invoke(
               :fetch_message,
               %{client | config: [provider_result: :invalid]},
               request,
               []
             )

    assert {:error, :invalid_provider_result} =
             Operations.invoke(
               :fetch_message,
               %{client | config: [provider_result: :missing_id]},
               request,
               []
             )

    page = %{data: %{"room_id" => "agentjido/chat#1"}}

    for provider_result <- [:invalid, :mixed] do
      assert {:error, :invalid_provider_result} =
               Operations.invoke(
                 :fetch_messages,
                 %{client | config: [provider_result: provider_result]},
                 page,
                 []
               )
    end
  end

  test "rejects a missing or empty token before transport I/O", %{client: client} do
    request = %{data: %{"room_id" => "agentjido/chat#1", "text" => "hello"}}

    assert {:error, {:not_attempted, :missing_token}} =
             Operations.invoke(:send_message, %{client | credentials: %{}}, request, [])

    assert {:error, {:not_attempted, :missing_token}} =
             Operations.invoke(
               :send_message,
               %{client | credentials: %{token: ""}},
               request,
               []
             )

    refute_received {:github_transport, _, _}
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

    edited = put_in(payload["action"], "edited")
    assert {:ok, delivery} = Jido.Chat.normalize(client, edited)
    assert [updated] = delivery.signals
    assert updated.type == "jido.chat.message.updated"
  end

  test "keeps normalized item order and reports unsupported items", %{client: client} do
    created = %{
      "repository" => %{"full_name" => "agentjido/chat"},
      "issue" => %{"number" => 1},
      "comment" => %{"id" => 1, "body" => "first", "user" => %{"id" => 2}}
    }

    assert {:ok, delivery} = Jido.Chat.normalize(client, [created, :invalid])
    assert [received, failed] = delivery.signals
    assert received.data["text"] == "first"
    assert failed.data["code"] == "unsupported_item"
    assert failed.data["item_index"] == 1

    assert {:error, _} = Jido.Chat.normalize(client, :invalid)

    missing_id = put_in(created["comment"]["id"], nil)
    assert {:error, _} = Jido.Chat.normalize(client, missing_id)
  end

  test "exposes the adapter, events, and unsupported boundary", %{client: client} do
    assert GitHub.adapter() == Adapter

    assert GitHub.event_definitions() == [
             MessageReceived,
             MessageUpdated,
             NormalizationFailed
           ]

    assert {:error, {:not_attempted, :unsupported}} =
             Adapter.invoke(client, %{type: "unknown"}, [])
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

  defp execute(client, definition, data) do
    request =
      Policy.new!(
        definition,
        Map.merge(data, %{
          "client_id" => client.id,
          "request_id" => "github:#{System.unique_integer([:positive])}"
        })
      )

    Jido.Chat.execute(client, request)
  end
end
