defmodule Jido.Chat.GitHub.AdapterTest do
  use ExUnit.Case, async: true

  alias Jido.Chat
  alias Jido.Chat.Adapter, as: ChatAdapter
  alias Jido.Chat.{EventEnvelope, WebhookRequest}
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

  test "declares a valid capability matrix" do
    assert :ok = ChatAdapter.validate_capabilities(Adapter)
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

  test "verifies GitHub webhook signatures against the raw body" do
    secret = "github-secret"
    raw = Jason.encode!(issue_payload())
    signature = github_signature(secret, raw)

    request =
      WebhookRequest.new(%{
        headers: %{"x-hub-signature-256" => signature},
        payload: issue_payload(),
        raw: raw
      })

    assert :ok = Adapter.verify_webhook(request, webhook_secret: secret)

    assert {:error, :invalid_signature} =
             Adapter.verify_webhook(request, webhook_secret: "wrong-secret")
  end

  test "parses issue webhooks into message envelopes" do
    request =
      WebhookRequest.new(%{
        headers: %{"x-github-event" => "issues", "x-github-delivery" => "delivery-1"},
        payload: issue_payload()
      })

    assert {:ok, %EventEnvelope{} = envelope} = Adapter.parse_event(request)
    assert envelope.adapter_name == :github
    assert envelope.event_type == :message
    assert envelope.thread_id == "github:agentjido/demo#42"
    assert envelope.payload.text == "Demo body"
    assert envelope.metadata == %{"delivery" => "delivery-1"}
  end

  test "routes a signed GitHub webhook through handle_webhook/3" do
    payload = issue_comment_payload()
    raw = Jason.encode!(payload)
    secret = "github-secret"

    chat =
      Chat.new(user_name: "jido", adapters: %{github: Adapter})
      |> Chat.on_new_message(~r/.*/, fn _thread, incoming ->
        send(self(), {:github_message, incoming})
      end)

    assert {:ok, _updated_chat, incoming} =
             Adapter.handle_webhook(chat, payload,
               headers: %{
                 "x-github-event" => "issue_comment",
                 "x-github-delivery" => "delivery-2",
                 "x-hub-signature-256" => github_signature(secret, raw)
               },
               raw_body: raw,
               webhook_secret: secret
             )

    assert incoming.external_room_id == "agentjido/demo#42"
    assert incoming.external_message_id == "123"
    assert_received {:github_message, ^incoming}
  end

  test "treats GitHub ping webhooks as noop" do
    request =
      WebhookRequest.new(%{
        headers: %{"x-github-event" => "ping"},
        payload: %{"zen" => "Keep it logically awesome."}
      })

    assert {:ok, :noop} = Adapter.parse_event(request)
  end

  defp issue_comment_payload do
    %{
      "action" => "created",
      "repository" => %{"name" => "demo", "owner" => %{"login" => "agentjido"}},
      "issue" => %{
        "id" => 9,
        "number" => 42,
        "title" => "Demo",
        "created_at" => "2026-04-24T12:00:00Z"
      },
      "comment" => %{
        "id" => 123,
        "body" => "hello",
        "created_at" => "2026-04-24T12:00:01Z",
        "user" => %{"id" => 1, "login" => "mike"}
      }
    }
  end

  defp issue_payload do
    %{
      "action" => "opened",
      "repository" => %{"name" => "demo", "owner" => %{"login" => "agentjido"}},
      "issue" => %{
        "id" => 9,
        "number" => 42,
        "title" => "Demo",
        "body" => "Demo body",
        "created_at" => "2026-04-24T12:00:00Z",
        "html_url" => "https://github.test/agentjido/demo/issues/42",
        "user" => %{"id" => 1, "login" => "mike"}
      }
    }
  end

  defp github_signature(secret, raw) do
    digest = :crypto.mac(:hmac, :sha256, secret, raw) |> Base.encode16(case: :lower)
    "sha256=" <> digest
  end
end
