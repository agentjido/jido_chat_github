defmodule Jido.Chat.GitHub.Adapter do
  @moduledoc "GitHub Issues `Jido.Chat.Adapter` implementation."
  use Jido.Chat.Adapter

  alias Jido.Chat.{
    Author,
    EventEnvelope,
    Incoming,
    Message,
    MessagePage,
    Response,
    Thread,
    WebhookRequest,
    WebhookResponse
  }

  alias Jido.Chat.GitHub.Transport.ReqClient

  @impl true
  def channel_type, do: :github

  @impl true
  def capabilities do
    %{
      send_message: :native,
      edit_message: :native,
      delete_message: :native,
      fetch_thread: :native,
      fetch_message: :native,
      fetch_messages: :native,
      webhook: :native,
      verify_webhook: :native,
      parse_event: :native,
      format_webhook_response: :native,
      send_file: :unsupported,
      start_typing: :unsupported,
      add_reaction: :unsupported,
      remove_reaction: :unsupported,
      post_ephemeral: :unsupported,
      open_modal: :unsupported
    }
  end

  @impl true
  def transform_incoming(
        %{"comment" => comment, "issue" => issue, "repository" => repo} = payload
      ) do
    {:ok, incoming_from_comment(comment, issue, repo, payload)}
  end

  def transform_incoming(%{"issue" => issue, "repository" => repo} = payload) do
    {:ok, incoming_from_issue(issue, repo, payload)}
  end

  def transform_incoming(_), do: {:error, :unsupported_payload}

  @impl true
  def send_message(room_id, text, opts \\ []) do
    with {:ok, target} <- parse_room_id(room_id),
         {:ok, raw} <-
           transport(opts).create_issue_comment(
             target.owner,
             target.repo,
             target.issue_number,
             text,
             opts
           ) do
      {:ok, response_from_comment(raw, room_id)}
    end
  end

  @impl true
  def edit_message(room_id, comment_id, text, opts \\ []) do
    with {:ok, target} <- parse_room_id(room_id),
         {:ok, raw} <-
           transport(opts).update_issue_comment(target.owner, target.repo, comment_id, text, opts) do
      {:ok, response_from_comment(raw, room_id)}
    end
  end

  @impl true
  def delete_message(room_id, comment_id, opts \\ []) do
    with {:ok, target} <- parse_room_id(room_id) do
      transport(opts).delete_issue_comment(target.owner, target.repo, comment_id, opts)
    end
  end

  @impl true
  def fetch_thread(room_id, opts \\ []) do
    with {:ok, target} <- parse_room_id(room_id),
         {:ok, issue} <-
           transport(opts).get_issue(target.owner, target.repo, target.issue_number, opts) do
      {:ok,
       Thread.new(%{
         id: thread_id(room_id),
         adapter_name: :github,
         adapter: __MODULE__,
         external_room_id: room_id,
         external_thread_id: to_string(issue["id"] || issue["node_id"] || target.issue_number),
         metadata: %{"issue" => issue}
       })}
    end
  end

  @impl true
  def fetch_message(room_id, comment_id, opts \\ []) do
    with {:ok, target} <- parse_room_id(room_id),
         {:ok, comment} <-
           transport(opts).get_issue_comment(target.owner, target.repo, comment_id, opts) do
      {:ok, message_from_comment(comment, room_id)}
    end
  end

  @impl true
  def fetch_messages(room_id, opts \\ []) do
    with {:ok, target} <- parse_room_id(room_id),
         {:ok, comments} <-
           transport(opts).list_issue_comments(
             target.owner,
             target.repo,
             target.issue_number,
             opts
           ) do
      {:ok,
       MessagePage.new(%{
         messages: Enum.map(comments, &message_from_comment(&1, room_id)),
         next_cursor: nil,
         metadata: %{"raw" => comments}
       })}
    end
  end

  @impl true
  def handle_webhook(%Jido.Chat{} = chat, payload, opts \\ []) when is_map(payload) do
    request =
      WebhookRequest.new(%{
        adapter_name: :github,
        headers: opts[:headers] || %{},
        payload: payload,
        raw: opts[:raw_body] || opts[:raw] || payload,
        metadata: %{raw_body: opts[:raw_body] || opts[:raw]}
      })

    with :ok <- verify_webhook(request, opts),
         {:ok, parsed_event} <- parse_event(request, opts) do
      route_parsed_event(chat, parsed_event, opts, request)
    end
  end

  @impl true
  def verify_webhook(request, opts \\ [])

  def verify_webhook(%WebhookRequest{} = request, opts) do
    secret = Keyword.get(opts, :webhook_secret) || System.get_env("GITHUB_WEBHOOK_SECRET")
    signature = WebhookRequest.header(request, "x-hub-signature-256")
    raw = raw_body(request)

    cond do
      secret in [nil, ""] -> {:error, :missing_webhook_secret}
      signature in [nil, ""] -> {:error, :missing_signature}
      secure_compare(signature, "sha256=" <> hmac(secret, raw)) -> :ok
      true -> {:error, :invalid_signature}
    end
  end

  def verify_webhook(request, opts) when is_map(request) do
    request
    |> WebhookRequest.new()
    |> verify_webhook(opts)
  end

  @impl true
  def parse_event(request, opts \\ [])

  def parse_event(%WebhookRequest{} = request, _opts) do
    event = WebhookRequest.header(request, "x-github-event")
    action = request.payload["action"]

    case {event, action} do
      {"ping", _} ->
        {:ok, :noop}

      {"issue_comment", action} when action in ["created", "edited"] ->
        with {:ok, incoming} <- transform_incoming(request.payload) do
          {:ok, envelope(incoming, request)}
        end

      {"issues", action} when action in ["opened", "edited", "reopened"] ->
        with {:ok, incoming} <- transform_incoming(request.payload) do
          {:ok, envelope(incoming, request)}
        end

      _ ->
        {:ok, :noop}
    end
  end

  def parse_event(request, opts) when is_map(request) do
    request
    |> WebhookRequest.new()
    |> parse_event(opts)
  end

  @impl true
  def format_webhook_response({:ok, _chat, _incoming}, _opts), do: WebhookResponse.accepted()
  def format_webhook_response({:ok, :noop}, _opts), do: WebhookResponse.accepted()

  def format_webhook_response({:error, reason}, _opts),
    do: WebhookResponse.error(400, inspect(reason))

  def format_webhook_response(_, _opts), do: WebhookResponse.accepted()

  defp incoming_from_comment(comment, issue, repo, payload) do
    room_id = room_id(repo, issue)
    user = comment["user"] || %{}

    Incoming.new(%{
      external_room_id: room_id,
      external_thread_id: to_string(issue["id"] || issue["node_id"] || issue["number"]),
      external_message_id: to_string(comment["id"]),
      external_user_id: user["id"] || user["login"],
      text: comment["body"] || "",
      timestamp: comment["created_at"],
      author: author(user),
      chat_type: :github_issue,
      chat_title: issue["title"],
      raw: payload,
      metadata: %{"html_url" => comment["html_url"], "issue_number" => issue["number"]}
    })
  end

  defp incoming_from_issue(issue, repo, payload) do
    room_id = room_id(repo, issue)
    user = issue["user"] || %{}

    Incoming.new(%{
      external_room_id: room_id,
      external_thread_id: to_string(issue["id"] || issue["node_id"] || issue["number"]),
      external_message_id: to_string(issue["id"] || issue["number"]),
      external_user_id: user["id"] || user["login"],
      text: issue["body"] || issue["title"] || "",
      timestamp: issue["created_at"],
      author: author(user),
      chat_type: :github_issue,
      chat_title: issue["title"],
      raw: payload,
      metadata: %{
        "html_url" => issue["html_url"],
        "issue_number" => issue["number"],
        "issue_event" => true
      }
    })
  end

  defp message_from_comment(comment, room_id) do
    Message.new(%{
      id: to_string(comment["id"]),
      thread_id: thread_id(room_id),
      channel_id: room_id,
      text: comment["body"],
      raw: comment,
      author: author(comment["user"] || %{}),
      created_at: comment["created_at"],
      updated_at: comment["updated_at"],
      external_message_id: to_string(comment["id"]),
      external_room_id: room_id,
      metadata: %{"html_url" => comment["html_url"]}
    })
  end

  defp response_from_comment(comment, room_id) do
    Response.new(%{
      external_message_id: to_string(comment["id"]),
      external_room_id: room_id,
      timestamp: comment["created_at"],
      channel_type: :github,
      raw: comment,
      metadata: %{"html_url" => comment["html_url"]}
    })
  end

  defp route_parsed_event(chat, :noop, _opts, %WebhookRequest{} = request) do
    {:ok, chat, synthetic_incoming(request, :noop)}
  end

  defp route_parsed_event(chat, %EventEnvelope{} = envelope, opts, _request) do
    with {:ok, updated_chat, routed_envelope} <-
           Jido.Chat.process_event(chat, :github, envelope, opts),
         {:ok, incoming} <- incoming_from_event(routed_envelope) do
      {:ok, updated_chat, incoming}
    end
  end

  defp incoming_from_event(%EventEnvelope{event_type: :message, payload: %Incoming{} = incoming}),
    do: {:ok, incoming}

  defp incoming_from_event(_), do: {:error, :unsupported_event_type}

  defp synthetic_incoming(%WebhookRequest{} = request, event_type) do
    Incoming.new(%{
      external_room_id: "github",
      external_user_id: nil,
      external_message_id: WebhookRequest.header(request, "x-github-delivery"),
      text: nil,
      raw: request.payload,
      metadata: %{event_type: event_type}
    })
  end

  defp author(user) do
    Author.new(%{
      user_id: to_string(user["id"] || user["login"] || "unknown"),
      user_name: user["login"] || "unknown",
      full_name: user["login"],
      is_bot: user["type"] == "Bot",
      metadata: user
    })
  end

  defp envelope(incoming, request) do
    EventEnvelope.new(%{
      adapter_name: :github,
      event_type: :message,
      thread_id: thread_id(incoming.external_room_id),
      channel_id: incoming.external_room_id,
      message_id: to_string(incoming.external_message_id),
      payload: incoming,
      raw: request.payload,
      metadata: %{"delivery" => WebhookRequest.header(request, "x-github-delivery")}
    })
  end

  defp room_id(repo, issue), do: "#{repo["owner"]["login"]}/#{repo["name"]}##{issue["number"]}"
  defp thread_id(room_id), do: "github:#{room_id}"

  defp parse_room_id(room_id) when is_binary(room_id) do
    case Regex.run(~r{\A([^/\s]+)/([^#\s]+)#(\d+)\z}, room_id) do
      [_, owner, repo, issue_number] ->
        {:ok, %{owner: owner, repo: repo, issue_number: String.to_integer(issue_number)}}

      _ ->
        {:error, :invalid_room_id}
    end
  end

  defp parse_room_id(_), do: {:error, :invalid_room_id}

  defp transport(opts), do: Keyword.get(opts, :transport, ReqClient)
  defp raw_body(%WebhookRequest{raw: raw}) when is_binary(raw), do: raw
  defp raw_body(%WebhookRequest{metadata: %{"raw_body" => raw}}) when is_binary(raw), do: raw
  defp raw_body(%WebhookRequest{metadata: %{raw_body: raw}}) when is_binary(raw), do: raw
  defp raw_body(%WebhookRequest{payload: payload}), do: Jason.encode!(payload)

  defp hmac(secret, data),
    do: :crypto.mac(:hmac, :sha256, secret, data) |> Base.encode16(case: :lower)

  defp secure_compare(a, b) when byte_size(a) == byte_size(b) do
    :crypto.hash_equals(a, b)
  end

  defp secure_compare(_, _), do: false
end
