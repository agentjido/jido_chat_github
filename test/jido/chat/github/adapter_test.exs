defmodule Jido.Chat.GitHub.AdapterTest do
  use ExUnit.Case, async: true

  alias Jido.Chat
  alias Jido.Chat.Adapter, as: ChatAdapter

  alias Jido.Chat.{
    EventEnvelope,
    MessagePage,
    PostPayload,
    ReactionEvent,
    ThreadPage,
    WebhookRequest
  }

  alias Jido.Chat.GitHub.Adapter

  defmodule FakeTransport do
    @behaviour Jido.Chat.GitHub.Transport

    def create_issue("agentjido", "demo", title, body, opts) do
      send(self(), {:github_create_issue, title, body, Keyword.take(opts, [:labels])})

      {:ok,
       %{
         "id" => 9001,
         "number" => 77,
         "title" => title,
         "body" => body,
         "created_at" => "2026-04-24T12:00:00Z",
         "html_url" => "https://github.test/issue/77",
         "user" => %{"id" => 1, "login" => "mike"}
       }}
    end

    def create_issue_comment("agentjido", "demo", 42, body, _opts) do
      send(self(), {:github_create_comment, body})

      {:ok,
       %{
         "id" => 123,
         "body" => body,
         "created_at" => "2026-04-24T12:00:00Z",
         "html_url" => "https://github.test/comment"
       }}
    end

    def update_issue_comment(_, _, _, body, _opts) do
      send(self(), {:github_update_comment, body})
      {:ok, %{"id" => 123, "body" => body}}
    end

    def delete_issue_comment(_, _, _, _opts), do: :ok

    def get_issue(_, _, issue_number, _opts),
      do:
        {:ok,
         %{
           "id" => 9,
           "number" => issue_number,
           "title" => "Demo",
           "body" => "Demo body",
           "created_at" => "2026-04-24T12:00:00Z",
           "updated_at" => "2026-04-24T12:00:01Z",
           "html_url" => "https://github.test/issue",
           "user" => %{"id" => 1, "login" => "mike"}
         }}

    def list_issue_comments(_, _, _, _opts),
      do: {:ok, [%{"id" => 123, "body" => "hello", "user" => %{"login" => "mike"}}]}

    def get_issue_comment(_, _, _, _opts),
      do: {:ok, %{"id" => 123, "body" => "hello", "user" => %{"login" => "mike"}}}

    def list_issues(_, _, _opts),
      do:
        {:ok,
         [
           %{
             "id" => 9,
             "number" => 42,
             "title" => "Demo",
             "body" => "Demo body",
             "comments" => 2,
             "created_at" => "2026-04-24T12:00:00Z",
             "updated_at" => "2026-04-24T12:10:00Z",
             "user" => %{"id" => 1, "login" => "mike"}
           }
         ]}

    def create_issue_reaction(_, _, issue_number, content, _opts) do
      send(self(), {:github_create_issue_reaction, issue_number, content})
      {:ok, %{"id" => 456, "content" => content}}
    end

    def create_issue_comment_reaction(_, _, comment_id, content, _opts) do
      send(self(), {:github_create_comment_reaction, comment_id, content})
      {:ok, %{"id" => 456, "content" => content}}
    end

    def list_issue_reactions(_, _, _issue_number, _opts),
      do: {:ok, [%{"id" => 456, "content" => "rocket", "user" => %{"login" => "mike"}}]}

    def list_issue_comment_reactions(_, _, _comment_id, _opts),
      do: {:ok, [%{"id" => 456, "content" => "rocket", "user" => %{"login" => "mike"}}]}

    def delete_issue_reaction(_, _, issue_number, reaction_id, _opts) do
      send(self(), {:github_delete_issue_reaction, issue_number, reaction_id})
      :ok
    end

    def delete_issue_comment_reaction(_, _, comment_id, reaction_id, _opts) do
      send(self(), {:github_delete_comment_reaction, comment_id, reaction_id})
      :ok
    end
  end

  test "declares a valid capability matrix" do
    assert :ok = ChatAdapter.validate_capabilities(Adapter)
  end

  test "sends an issue comment" do
    assert {:ok, response} =
             Adapter.send_message("agentjido/demo#42", "hello", transport: FakeTransport)

    assert response.external_message_id == "123"
    assert response.external_room_id == "agentjido/demo#42"
    assert_received {:github_create_comment, "hello"}
  end

  test "creates repository issues for channel-level posts" do
    assert {:ok, response} =
             Adapter.post_channel_message("agentjido/demo", "Beta thread\n\nBody text",
               transport: FakeTransport,
               labels: ["beta"]
             )

    assert response.external_message_id == "77"
    assert response.external_room_id == "agentjido/demo#77"

    assert_received {:github_create_issue, "Beta thread", body, [labels: ["beta"]]}
    assert body =~ "Beta thread"
    assert body =~ "Body text"

    payload =
      PostPayload.new(%{
        kind: :markdown,
        markdown: "## With media",
        files: [%{kind: :image, url: "https://example.test/image.png", filename: "image.png"}],
        metadata: %{title: "Issue from payload"}
      })

    assert {:ok, _response} =
             Adapter.post_message("agentjido/demo", payload, transport: FakeTransport)

    assert_received {:github_create_issue, "Issue from payload", rich_body, []}
    assert rich_body =~ "## With media"
    assert rich_body =~ "![image.png](https://example.test/image.png)"
  end

  test "posts rich markdown payload with reply context and remote media" do
    payload =
      PostPayload.new(%{
        kind: :markdown,
        markdown: "**hello**",
        files: [
          %{
            kind: :image,
            url: "https://example.test/diagram.png",
            filename: "diagram.png",
            metadata: %{alt_text: "Diagram"}
          },
          %{kind: :file, url: "https://example.test/report.pdf", filename: "report.pdf"}
        ]
      })

    assert {:ok, response} =
             Adapter.post_message("agentjido/demo#42", payload,
               transport: FakeTransport,
               reply_to_id: 111,
               reply_author: "mike",
               reply_to_text: "parent\nmessage"
             )

    assert response.external_message_id == "123"
    assert %{attachments: [_image, _file]} = response.metadata

    assert_received {:github_create_comment, body}
    assert body =~ "Replying to mike in 111:"
    assert body =~ "> parent\n> message"
    assert body =~ "**hello**"
    assert body =~ "![Diagram](https://example.test/diagram.png)"
    assert body =~ "[report.pdf](https://example.test/report.pdf)"
  end

  test "sends remote files as GitHub markdown links and rejects local uploads" do
    assert {:ok, _response} =
             Adapter.send_file(
               "agentjido/demo#42",
               %{url: "https://example.test/report.pdf", filename: "report.pdf"},
               transport: FakeTransport,
               caption: "See report"
             )

    assert_received {:github_create_comment, body}
    assert body =~ "See report"
    assert body =~ "[report.pdf](https://example.test/report.pdf)"

    assert {:error, {:unsupported_file_upload, :github_requires_public_url}} =
             Adapter.send_file("agentjido/demo#42", %{path: "/tmp/report.pdf"},
               transport: FakeTransport
             )
  end

  test "normalizes issue comment webhooks" do
    payload = %{
      "action" => "created",
      "repository" => %{"name" => "demo", "owner" => %{"login" => "agentjido"}},
      "issue" => %{"id" => 9, "number" => 42, "title" => "Demo"},
      "comment" => %{
        "id" => 123,
        "body" => "hello ![Screenshot](https://example.test/screenshot.png)",
        "user" => %{"id" => 1, "login" => "mike"}
      }
    }

    assert {:ok, incoming} = Adapter.transform_incoming(payload)
    assert incoming.external_room_id == "agentjido/demo#42"
    assert incoming.text == "hello ![Screenshot](https://example.test/screenshot.png)"
    assert [%{kind: :image, url: "https://example.test/screenshot.png"}] = incoming.media
  end

  test "lists and opens GitHub issues as chat threads" do
    assert {:ok, %ThreadPage{} = page} =
             Adapter.list_threads("agentjido/demo", transport: FakeTransport)

    assert [summary] = page.threads
    assert summary.id == "github:agentjido/demo#42"
    assert summary.reply_count == 2
    assert summary.root_message.text == "Demo body"

    assert {:ok, thread} = Adapter.open_thread("agentjido/demo", 42, transport: FakeTransport)
    assert thread.id == "github:agentjido/demo#42"
    assert thread.external_room_id == "agentjido/demo#42"

    assert {:ok, %MessagePage{} = message_page} =
             Adapter.fetch_channel_messages("agentjido/demo", transport: FakeTransport)

    assert [message] = message_page.messages
    assert message.external_message_id == "42"
    assert message.external_room_id == "agentjido/demo"
    assert message.metadata["thread_room_id"] == "agentjido/demo#42"
  end

  test "adds and removes GitHub comment and issue reactions" do
    assert :ok =
             ChatAdapter.add_reaction(
               Adapter,
               "agentjido/demo#42",
               "123",
               "rocket",
               transport: FakeTransport
             )

    assert_received {:github_create_comment_reaction, "123", "rocket"}

    assert :ok =
             ChatAdapter.remove_reaction(
               Adapter,
               "agentjido/demo#42",
               "123",
               "rocket",
               transport: FakeTransport,
               user_login: "mike"
             )

    assert_received {:github_delete_comment_reaction, "123", 456}

    assert :ok =
             ChatAdapter.add_reaction(
               Adapter,
               "agentjido/demo#42",
               "issue",
               "rocket",
               transport: FakeTransport,
               target: :issue
             )

    assert_received {:github_create_issue_reaction, 42, "rocket"}
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

  test "parses GitHub reaction webhooks" do
    request =
      WebhookRequest.new(%{
        headers: %{"x-github-event" => "reaction", "x-github-delivery" => "delivery-3"},
        payload: reaction_payload()
      })

    assert {:ok, %EventEnvelope{} = envelope} = Adapter.parse_event(request)
    assert envelope.event_type == :reaction
    assert %ReactionEvent{} = envelope.payload
    assert envelope.payload.channel_id == "agentjido/demo#42"
    assert envelope.payload.message_id == "123"
    assert envelope.payload.emoji == "rocket"
    assert envelope.payload.added == true
  end

  test "routes signed GitHub reaction webhooks through handle_webhook/3" do
    payload = reaction_payload()
    raw = Jason.encode!(payload)
    secret = "github-secret"

    chat =
      Chat.new(user_name: "jido", adapters: %{github: Adapter})
      |> Chat.on_reaction("rocket", fn reaction ->
        send(self(), {:github_reaction, reaction})
      end)

    assert {:ok, _updated_chat, incoming} =
             Adapter.handle_webhook(chat, payload,
               headers: %{
                 "x-github-event" => "reaction",
                 "x-github-delivery" => "delivery-4",
                 "x-hub-signature-256" => github_signature(secret, raw)
               },
               raw_body: raw,
               webhook_secret: secret
             )

    assert incoming.external_room_id == "agentjido/demo#42"
    assert incoming.external_message_id == "123"
    assert incoming.metadata["event_type"] == :reaction
    assert_received {:github_reaction, %ReactionEvent{emoji: "rocket"}}
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

  defp reaction_payload do
    %{
      "action" => "created",
      "repository" => %{"name" => "demo", "owner" => %{"login" => "agentjido"}},
      "issue" => %{"id" => 9, "number" => 42, "title" => "Demo"},
      "comment" => %{"id" => 123, "html_url" => "https://github.test/comment"},
      "reaction" => %{
        "id" => 456,
        "content" => "rocket",
        "user" => %{"id" => 1, "login" => "mike"}
      }
    }
  end

  defp github_signature(secret, raw) do
    digest = :crypto.mac(:hmac, :sha256, secret, raw) |> Base.encode16(case: :lower)
    "sha256=" <> digest
  end
end
