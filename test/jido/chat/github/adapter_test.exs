defmodule Jido.Chat.GitHub.AdapterTest do
  use Jido.Chat.AdapterTestKit, adapter: Jido.Chat.GitHub.Adapter, async: true

  alias Jido.Chat
  alias Jido.Chat.Adapter, as: ChatAdapter

  alias Jido.Chat.{
    EventEnvelope,
    MessagePage,
    MessageSubject,
    Participant,
    PostPayload,
    ReactionEvent,
    ThreadPage,
    UserInfo,
    WebhookRequest
  }

  alias Jido.Chat.GitHub.Adapter
  alias Jido.Chat.GitHub.Transport.ReqClient

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

    def get_user("missing", _opts), do: {:error, {:github_api_error, 404, %{}}}

    def get_user(login, _opts) do
      {:ok,
       %{
         "id" => 99,
         "login" => login,
         "name" => "Ada Lovelace",
         "email" => "ada@example.test",
         "avatar_url" => "https://github.test/avatars/ada",
         "type" => "User",
         "html_url" => "https://github.test/#{login}"
       }}
    end

    def get_issue(_, _, 404, _opts), do: {:error, {:github_api_error, 404, %{}}}

    def get_issue(_, _, 43, _opts) do
      {:ok,
       %{
         "id" => 10,
         "number" => 43,
         "title" => "Resource contracts",
         "html_url" => "https://github.test/pull/43",
         "state" => "closed",
         "pull_request" => %{"url" => "https://api.github.test/pulls/43"},
         "user" => %{"id" => 1, "login" => "mike", "type" => "User"}
       }}
    end

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
           "state" => "open",
           "locked" => false,
           "labels" => [%{"name" => "enhancement"}],
           "user" => %{"id" => 1, "login" => "mike", "type" => "User"},
           "assignees" => [%{"id" => 2, "login" => "ada", "type" => "User"}]
         }}

    def list_issue_comments(_, _, 500, _opts),
      do: {:error, {:github_api_error, 503, %{"message" => "unavailable"}}}

    def list_issue_comments(_, _, 44, opts) do
      case {Keyword.get(opts, :page), Keyword.get(opts, :per_page)} do
        {1, 100} ->
          {:ok,
           Enum.map(1..100, fn id ->
             %{"id" => id, "user" => %{"id" => id, "login" => "user-#{id}"}}
           end)}

        {2, 100} ->
          {:ok,
           [
             %{"id" => 101, "user" => %{"id" => 1, "login" => "user-1"}},
             %{"id" => 102, "user" => %{"id" => 101, "login" => "user-101"}}
           ]}

        page ->
          {:error, {:unexpected_comment_page, page}}
      end
    end

    def list_issue_comments(_, _, 45, opts) do
      case {Keyword.get(opts, :page), Keyword.get(opts, :per_page)} do
        {1, 100} ->
          {:ok,
           Enum.map(1..100, fn id ->
             %{"id" => id, "user" => %{"id" => id, "login" => "user-#{id}"}}
           end)}

        {2, 100} ->
          {:error, {:github_api_error, 502, %{"message" => "unavailable"}}}

        page ->
          {:error, {:unexpected_comment_page, page}}
      end
    end

    def list_issue_comments(_, _, _, _opts),
      do:
        {:ok,
         [
           %{"id" => 123, "body" => "hello", "user" => %{"id" => 1, "login" => "mike"}},
           %{
             "id" => 124,
             "body" => "reviewed",
             "user" => %{"id" => 3, "login" => "review-bot", "type" => "Bot"}
           }
         ]}

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

  test "looks up a GitHub user as normalized user information" do
    assert {:ok, %UserInfo{} = user} =
             ChatAdapter.get_user(Adapter, "ada", transport: FakeTransport)

    assert user.id == "99"
    assert user.username == "ada"
    assert user.display_name == "Ada Lovelace"
    assert user.email == "ada@example.test"
    assert user.avatar_url == "https://github.test/avatars/ada"
    refute user.is_bot
    assert user.metadata["html_url"] == "https://github.test/ada"
  end

  test "uses GitHub account routes for numeric IDs and login routes for names" do
    assert_user_request_path(42, "/user/42")
    assert_user_request_path("42", "/user/42")
    assert_user_request_path("ada", "/users/ada")
  end

  test "sends GitHub comment page and size parameters to the transport" do
    {port, server} = start_http_server(self(), "[]")

    assert {:ok, []} =
             ReqClient.list_issue_comments("agentjido", "demo", 42,
               page: 2,
               per_page: 100,
               base_url: "http://127.0.0.1:#{port}"
             )

    assert_receive {:github_request, request_line}
    ["GET", target, "HTTP/1.1"] = String.split(request_line, " ")

    assert %URI{path: "/repos/agentjido/demo/issues/42/comments", query: query} =
             URI.parse(target)

    assert URI.decode_query(query) == %{"page" => "2", "per_page" => "100"}
    assert_receive {:http_server_stopped, ^server}
  end

  test "fetches an issue as a normalized message subject" do
    assert {:ok, %MessageSubject{} = subject} =
             ChatAdapter.fetch_subject(Adapter, "agentjido/demo#42", transport: FakeTransport)

    assert subject.type == "issue"
    assert subject.id == "42"
    assert subject.title == "Demo"
    assert subject.url == "https://github.test/issue"
    assert subject.status == "open"
    assert subject.metadata["repository"] == "agentjido/demo"
    assert subject.metadata["labels"] == ["enhancement"]

    assert {:ok, %MessageSubject{type: "pull_request", id: "43", status: "closed"}} =
             ChatAdapter.fetch_subject(Adapter, "agentjido/demo",
               issue_number: 43,
               transport: FakeTransport
             )
  end

  test "returns unique issue authors, assignees, and commenters as participants" do
    assert {:ok, participants} =
             ChatAdapter.get_thread_participants(Adapter, "agentjido/demo#42",
               transport: FakeTransport
             )

    assert Enum.all?(participants, &match?(%Participant{}, &1))
    assert Enum.map(participants, & &1.id) == ["1", "2", "3"]
    assert Enum.map(participants, & &1.identity.username) == ["mike", "ada", "review-bot"]
    assert Enum.map(participants, & &1.type) == [:human, :human, :agent]
    assert Enum.all?(participants, &match?(%{github: _}, &1.external_ids))
  end

  test "gets participants from all GitHub comment pages and removes duplicates" do
    assert {:ok, participants} =
             ChatAdapter.get_thread_participants(Adapter, "agentjido/demo#44",
               transport: FakeTransport
             )

    assert length(participants) == 101
    assert Enum.count(participants, &(&1.id == "1")) == 1
    assert List.last(participants).id == "101"
  end

  test "returns an error from a later GitHub comment page" do
    assert {:error, {:github_api_error, 502, %{"message" => "unavailable"}}} =
             ChatAdapter.get_thread_participants(Adapter, "agentjido/demo#45",
               transport: FakeTransport
             )
  end

  test "keeps read receipts unsupported and passes provider errors through" do
    capabilities = ChatAdapter.capabilities(Adapter)

    assert capabilities.get_user == :native
    assert capabilities.fetch_subject == :native
    assert capabilities.get_thread_participants == :native
    assert capabilities.mark_as_read == :unsupported

    assert {:error, :unsupported} =
             ChatAdapter.mark_as_read(Adapter, "agentjido/demo#42", "123")

    assert {:error, {:github_api_error, 404, %{}}} =
             ChatAdapter.get_user(Adapter, "missing", transport: FakeTransport)

    assert {:error, {:github_api_error, 404, %{}}} =
             ChatAdapter.fetch_subject(Adapter, "agentjido/demo#404", transport: FakeTransport)

    assert {:error, {:github_api_error, 503, %{"message" => "unavailable"}}} =
             ChatAdapter.get_thread_participants(Adapter, "agentjido/demo#500",
               transport: FakeTransport
             )
  end

  capability_test :send_message, "normalizes a sent issue comment" do
    result = Adapter.send_message("agentjido/demo#42", "hello", transport: FakeTransport)
    assert {:ok, response} = assert_capability_result(@adapter, :send_message, result)

    assert response.external_message_id == "123"
    assert response.external_room_id == "agentjido/demo#42"
    assert_received {:github_create_comment, "hello"}
  end

  capability_test :post_channel_message, "normalizes repository issues as channel posts" do
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

  capability_test :post_message, "posts rich markdown with reply context and remote media" do
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

  capability_test :send_file, "links remote files and rejects local uploads" do
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
        "body" =>
          "hello ![PNG](https://example.test/screenshot.png?token=signed) " <>
            "![JPEG](https://example.test/photo.jpg) " <>
            "![Encoded](https://example.test/photo%2EPNG?token=signed) " <>
            "![Unknown](https://example.test/assets/image) " <>
            "![Misleading](https://example.test/report.pdf) " <>
            "![Malformed](https://example.test/photo%ZZ.png)",
        "user" => %{"id" => 1, "login" => "mike"}
      }
    }

    assert {:ok, incoming} = Adapter.transform_incoming(payload)
    assert incoming.external_room_id == "agentjido/demo#42"
    assert [png, jpeg, encoded, extensionless, misleading, malformed] = incoming.media

    assert_media(png, kind: :image, media_type: "image/png")
    assert png.url == "https://example.test/screenshot.png?token=signed"

    assert_media(jpeg, kind: :image, media_type: "image/jpeg")

    assert_media(encoded, kind: :image, media_type: "image/png")
    assert encoded.filename == "photo.PNG"

    assert_media(extensionless, kind: :image, media_type: nil)

    assert_media(misleading, kind: :image, media_type: nil)

    assert_media(malformed, kind: :image, media_type: nil)
    assert malformed.filename == nil

    assert_json_round_trip(incoming)
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

    assert %EventEnvelope{} = envelope = assert_webhook_event(@adapter, request)
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

  defp assert_user_request_path(user_id, expected_path) do
    {port, server} = start_http_server(self())

    assert {:ok, %{}} = ReqClient.get_user(user_id, base_url: "http://127.0.0.1:#{port}")
    assert_receive {:github_request, "GET " <> ^expected_path <> " HTTP/1.1"}
    assert_receive {:http_server_stopped, ^server}
  end

  defp start_http_server(parent, response_body \\ "{}") do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listener)

    server =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        request_line = receive_http_request(socket, "") |> String.split("\r\n", parts: 2) |> hd()
        send(parent, {:github_request, request_line})

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(response_body)}\r\n\r\n#{response_body}"
          )

        :gen_tcp.close(socket)
        :gen_tcp.close(listener)
        send(parent, {:http_server_stopped, self()})
      end)

    {port, server}
  end

  defp receive_http_request(socket, request) do
    case :binary.match(request, "\r\n\r\n") do
      :nomatch ->
        {:ok, chunk} = :gen_tcp.recv(socket, 0)
        receive_http_request(socket, request <> chunk)

      _match ->
        request
    end
  end
end
