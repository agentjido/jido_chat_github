defmodule Jido.Chat.GitHub.Adapter do
  @moduledoc "GitHub Issues `Jido.Chat.Adapter` implementation."
  use Jido.Chat.Adapter

  alias Jido.Chat.{
    Attachment,
    Author,
    EventEnvelope,
    FileUpload,
    Incoming,
    Media,
    Message,
    MessagePage,
    PostPayload,
    ReactionEvent,
    Response,
    Thread,
    ThreadPage,
    ThreadSummary,
    WebhookRequest,
    WebhookResponse
  }

  alias Jido.Chat.GitHub.Transport.ReqClient

  @github_reactions %{
    "+1" => "+1",
    "thumbsup" => "+1",
    "thumbs_up" => "+1",
    <<0x1F44D::utf8>> => "+1",
    "-1" => "-1",
    "thumbsdown" => "-1",
    "thumbs_down" => "-1",
    <<0x1F44E::utf8>> => "-1",
    "laugh" => "laugh",
    "smile" => "laugh",
    <<0x1F604::utf8>> => "laugh",
    "confused" => "confused",
    <<0x1F615::utf8>> => "confused",
    "heart" => "heart",
    <<0x2764::utf8>> => "heart",
    <<0x2764::utf8, 0xFE0F::utf8>> => "heart",
    "hooray" => "hooray",
    "tada" => "hooray",
    <<0x1F389::utf8>> => "hooray",
    "rocket" => "rocket",
    <<0x1F680::utf8>> => "rocket",
    "eyes" => "eyes",
    <<0x1F440::utf8>> => "eyes"
  }

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
      list_threads: :native,
      open_thread: :native,
      post_message: :native,
      post_channel_message: :native,
      webhook: :native,
      verify_webhook: :native,
      parse_event: :native,
      format_webhook_response: :native,
      send_file: :native,
      start_typing: :unsupported,
      add_reaction: :native,
      remove_reaction: :native,
      post_ephemeral: :unsupported,
      open_modal: :unsupported,
      fetch_channel_messages: :native,
      markdown: :native,
      multi_file: :native
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
         {:ok, body} <- render_text_body(text, opts),
         {:ok, raw} <-
           transport(opts).create_issue_comment(
             target.owner,
             target.repo,
             target.issue_number,
             body,
             opts
           ) do
      {:ok, response_from_comment(raw, room_id)}
    end
  end

  @impl true
  def post_message(room_id, payload, opts \\ [])

  def post_message(room_id, %PostPayload{} = payload, opts) do
    case parse_room_id(room_id) do
      {:ok, target} ->
        post_thread_payload(room_id, target, payload, opts)

      {:error, _reason} ->
        post_repo_payload(room_id, payload, opts)
    end
  end

  def post_message(room_id, payload, opts) when is_map(payload) do
    post_message(room_id, PostPayload.new(payload), opts)
  end

  @impl true
  def post_channel_message(repo_id, text, opts \\ []) do
    post_repo_payload(repo_id, PostPayload.text(text), opts)
  end

  @impl true
  def send_file(room_id, file, opts \\ []) do
    upload = FileUpload.normalize(file)
    caption = Keyword.get(opts, :caption) || Keyword.get(opts, :text)

    payload =
      PostPayload.new(%{
        kind: :text,
        text: caption,
        files: [upload],
        metadata: Keyword.get(opts, :metadata, %{})
      })

    post_message(room_id, payload, Keyword.drop(opts, [:caption, :text]))
  end

  @impl true
  def edit_message(room_id, comment_id, text, opts \\ []) do
    with {:ok, target} <- parse_room_id(room_id),
         {:ok, body} <- render_text_body(text, opts),
         {:ok, raw} <-
           transport(opts).update_issue_comment(target.owner, target.repo, comment_id, body, opts) do
      {:ok, response_from_comment(raw, room_id, :edited)}
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
      {:ok, thread_from_issue(issue, target)}
    end
  end

  @impl true
  def open_thread(room_or_repo_id, issue_number, opts \\ []) do
    with {:ok, room_id} <- open_thread_room_id(room_or_repo_id, issue_number) do
      fetch_thread(room_id, opts)
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
  def list_threads(repo_id, opts \\ []) do
    with {:ok, target} <- parse_repo_id(repo_id),
         {:ok, issues} <- transport(opts).list_issues(target.owner, target.repo, opts) do
      threads =
        issues
        |> Enum.reject(&pull_request_issue?/1)
        |> Enum.map(&thread_summary_from_issue(&1, target))

      {:ok,
       ThreadPage.new(%{
         threads: threads,
         next_cursor: nil,
         metadata: %{"raw" => issues}
       })}
    end
  end

  @impl true
  def fetch_channel_messages(repo_id, opts \\ []) do
    with {:ok, target} <- parse_repo_id(repo_id),
         {:ok, issues} <- transport(opts).list_issues(target.owner, target.repo, opts) do
      messages =
        issues
        |> Enum.reject(&pull_request_issue?/1)
        |> Enum.map(&issue_message_from_issue(&1, target))

      {:ok,
       MessagePage.new(%{
         messages: messages,
         next_cursor: nil,
         metadata: %{"raw" => issues}
       })}
    end
  end

  @impl true
  def add_reaction(room_id, message_id, emoji, opts \\ []) do
    with {:ok, target} <- parse_room_id(room_id),
         {:ok, content} <- github_reaction(emoji) do
      create_reaction(target, message_id, content, opts)
    end
  end

  defp create_reaction(target, message_id, content, opts) do
    case reaction_target(opts) do
      :issue ->
        transport(opts).create_issue_reaction(
          target.owner,
          target.repo,
          target.issue_number,
          content,
          opts
        )

      :comment ->
        transport(opts).create_issue_comment_reaction(
          target.owner,
          target.repo,
          message_id,
          content,
          opts
        )
    end
    |> case do
      {:ok, _reaction} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def remove_reaction(room_id, message_id, emoji, opts \\ []) do
    with {:ok, target} <- parse_room_id(room_id),
         {:ok, content} <- github_reaction(emoji),
         {:ok, reaction_id} <- reaction_id(target, message_id, content, opts) do
      case reaction_target(opts) do
        :issue ->
          transport(opts).delete_issue_reaction(
            target.owner,
            target.repo,
            target.issue_number,
            reaction_id,
            opts
          )

        :comment ->
          transport(opts).delete_issue_comment_reaction(
            target.owner,
            target.repo,
            message_id,
            reaction_id,
            opts
          )
      end
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

      {"reaction", action} when action in ["created", "deleted"] ->
        with {:ok, reaction} <- reaction_from_payload(request.payload) do
          {:ok, reaction_envelope(reaction, request)}
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
      media: media_from_markdown(comment["body"]),
      metadata: %{"html_url" => comment["html_url"], "issue_number" => issue["number"]}
    })
  end

  defp incoming_from_issue(issue, repo, payload) do
    room_id = room_id(repo, issue)
    user = issue["user"] || %{}

    Incoming.new(%{
      external_room_id: room_id,
      external_thread_id: to_string(issue["id"] || issue["node_id"] || issue["number"]),
      external_message_id: to_string(issue["number"] || issue["id"]),
      external_user_id: user["id"] || user["login"],
      text: issue["body"] || issue["title"] || "",
      timestamp: issue["created_at"],
      author: author(user),
      chat_type: :github_issue,
      chat_title: issue["title"],
      raw: payload,
      media: media_from_markdown(issue["body"]),
      metadata: %{
        "html_url" => issue["html_url"],
        "issue_number" => issue["number"],
        "issue_event" => true
      }
    })
  end

  defp post_thread_payload(room_id, target, %PostPayload{} = payload, opts) do
    with {:ok, body} <- render_post_body(payload, opts),
         {:ok, raw} <-
           transport(opts).create_issue_comment(
             target.owner,
             target.repo,
             target.issue_number,
             body,
             opts
           ) do
      {:ok,
       raw
       |> response_from_comment(room_id)
       |> put_response_metadata(:attachments, PostPayload.outbound_attachments(payload))}
    end
  end

  defp post_repo_payload(repo_id, %PostPayload{} = payload, opts) do
    with {:ok, target} <- parse_repo_id(repo_id),
         {:ok, title} <- issue_title(payload, opts),
         {:ok, body} <- render_post_body(payload, opts),
         {:ok, raw} <- transport(opts).create_issue(target.owner, target.repo, title, body, opts) do
      {:ok,
       raw
       |> response_from_issue(target)
       |> put_response_metadata(:attachments, PostPayload.outbound_attachments(payload))}
    end
  end

  defp message_from_comment(comment, room_id) do
    Message.new(%{
      id: to_string(comment["id"]),
      thread_id: thread_id(room_id),
      channel_id: room_id,
      text: comment["body"],
      raw: comment,
      author: author(comment["user"] || %{}),
      attachments: media_from_markdown(comment["body"]),
      created_at: comment["created_at"],
      updated_at: comment["updated_at"],
      external_message_id: to_string(comment["id"]),
      external_room_id: room_id,
      metadata: %{"html_url" => comment["html_url"]}
    })
  end

  defp issue_message_from_issue(issue, target) do
    repo = %{"name" => target.repo, "owner" => %{"login" => target.owner}}
    room_id = room_id(repo, issue)

    Message.new(%{
      id: to_string(issue["number"] || issue["id"]),
      thread_id: thread_id(room_id),
      channel_id: "github:#{target.owner}/#{target.repo}",
      text: issue["body"] || issue["title"],
      raw: issue,
      author: author(issue["user"] || %{}),
      attachments: media_from_markdown(issue["body"]),
      created_at: issue["created_at"],
      updated_at: issue["updated_at"],
      external_message_id: to_string(issue["number"] || issue["id"]),
      external_room_id: "#{target.owner}/#{target.repo}",
      metadata: %{
        "html_url" => issue["html_url"],
        "issue_number" => issue["number"],
        "thread_room_id" => room_id
      }
    })
  end

  defp response_from_comment(comment, room_id, status \\ :sent) do
    Response.new(%{
      external_message_id: to_string(comment["id"]),
      external_room_id: room_id,
      timestamp: comment["created_at"],
      channel_type: :github,
      status: status,
      raw: comment,
      metadata: %{"html_url" => comment["html_url"]}
    })
  end

  defp response_from_issue(issue, target, status \\ :sent) do
    room_id = "#{target.owner}/#{target.repo}##{issue["number"]}"

    Response.new(%{
      external_message_id: to_string(issue["number"] || issue["id"]),
      external_room_id: room_id,
      timestamp: issue["created_at"],
      channel_type: :github,
      status: status,
      raw: issue,
      metadata: %{
        "html_url" => issue["html_url"],
        "issue_number" => issue["number"],
        "repo" => "#{target.owner}/#{target.repo}"
      }
    })
  end

  defp put_response_metadata(%Response{} = response, key, value) do
    %{response | metadata: Map.put(response.metadata || %{}, key, value)}
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

  defp incoming_from_event(%EventEnvelope{
         event_type: :reaction,
         payload: %ReactionEvent{} = reaction
       }) do
    {:ok,
     Incoming.new(%{
       external_room_id: reaction.channel_id,
       external_user_id: reaction.user && reaction.user.user_id,
       external_message_id: reaction.message_id,
       text: nil,
       raw: reaction.raw,
       metadata:
         Map.merge(reaction.metadata || %{}, %{
           "event_type" => :reaction,
           "emoji" => reaction.emoji,
           "added" => reaction.added
         })
     })}
  end

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

  defp reaction_from_payload(%{"reaction" => reaction, "issue" => issue} = payload) do
    repo = payload["repository"] || %{}
    comment = payload["comment"]
    room_id = room_id(repo, issue)
    user = reaction["user"] || payload["sender"] || %{}
    message_id = if is_map(comment), do: comment["id"], else: issue["number"] || issue["id"]

    {:ok,
     ReactionEvent.new(%{
       adapter_name: :github,
       thread_id: thread_id(room_id),
       channel_id: room_id,
       message_id: to_string(message_id),
       emoji: reaction["content"],
       added: payload["action"] != "deleted",
       user: author(user),
       raw: payload,
       metadata: %{
         "reaction_id" => reaction["id"],
         "issue_number" => issue["number"],
         "html_url" => if(is_map(comment), do: comment["html_url"], else: issue["html_url"])
       }
     })}
  end

  defp reaction_from_payload(_payload), do: {:error, :unsupported_payload}

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

  defp reaction_envelope(%ReactionEvent{} = reaction, request) do
    EventEnvelope.new(%{
      adapter_name: :github,
      event_type: :reaction,
      thread_id: reaction.thread_id,
      channel_id: reaction.channel_id,
      message_id: reaction.message_id,
      payload: reaction,
      raw: request.payload,
      metadata: %{"delivery" => WebhookRequest.header(request, "x-github-delivery")}
    })
  end

  defp thread_from_issue(issue, target) do
    room_id = "#{target.owner}/#{target.repo}##{issue["number"] || target.issue_number}"

    Thread.new(%{
      id: thread_id(room_id),
      adapter_name: :github,
      adapter: __MODULE__,
      external_room_id: room_id,
      external_thread_id: to_string(issue["id"] || issue["node_id"] || target.issue_number),
      channel_id: "github:#{target.owner}/#{target.repo}",
      metadata: %{"issue" => issue}
    })
  end

  defp thread_summary_from_issue(issue, target) do
    repo = %{"name" => target.repo, "owner" => %{"login" => target.owner}}
    room_id = room_id(repo, issue)
    incoming = incoming_from_issue(issue, repo, %{"issue" => issue, "repository" => repo})

    ThreadSummary.new(%{
      id: thread_id(room_id),
      last_reply_at: issue["updated_at"],
      reply_count: issue["comments"] || 0,
      root_message:
        Message.from_incoming(incoming, adapter_name: :github, thread_id: thread_id(room_id)),
      metadata: %{"issue" => issue}
    })
  end

  defp render_text_body(text, opts) do
    text
    |> to_string()
    |> sections_with_reply(opts, [])
    |> render_sections()
  end

  defp render_post_body(%PostPayload{} = payload, opts) do
    base =
      payload.markdown || payload.formatted || PostPayload.display_text(payload) ||
        payload.fallback_text

    with {:ok, attachment_sections} <-
           attachment_sections(PostPayload.outbound_attachments(payload)) do
      base
      |> blank_to_nil()
      |> sections_with_reply(opts, attachment_sections)
      |> render_sections()
    end
  end

  defp issue_title(%PostPayload{} = payload, opts) do
    [
      Keyword.get(opts, :title),
      Keyword.get(opts, :issue_title),
      metadata_value(payload.metadata, :title),
      PostPayload.display_text(payload),
      payload.markdown,
      payload.formatted,
      payload.fallback_text
    ]
    |> Enum.find_value(&first_title_line/1)
    |> case do
      nil -> {:error, :missing_issue_title}
      title -> {:ok, String.slice(title, 0, 256)}
    end
  end

  defp first_title_line(nil), do: nil

  defp first_title_line(value) do
    value
    |> to_string()
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      case String.trim(line) do
        "" -> nil
        title -> title
      end
    end)
  end

  defp metadata_value(metadata, key) when is_map(metadata),
    do: Map.get(metadata, key) || Map.get(metadata, to_string(key))

  defp metadata_value(_metadata, _key), do: nil

  defp sections_with_reply(base, opts, extra_sections) do
    [reply_section(opts), blank_to_nil(base) | extra_sections]
  end

  defp render_sections(sections) do
    body =
      sections
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")
      |> String.trim()

    if body == "", do: {:error, :empty_message}, else: {:ok, body}
  end

  defp reply_section(opts) do
    %{
      text: Keyword.get(opts, :reply_to_text) || Keyword.get(opts, :quote_text),
      message: Keyword.get(opts, :reply_to_id) || Keyword.get(opts, :quote_id),
      author: Keyword.get(opts, :reply_author) || Keyword.get(opts, :quote_author)
    }
    |> render_reply_section()
  end

  defp render_reply_section(%{text: text, message: message, author: author}) do
    text = blank_to_nil(text)
    message = blank_to_nil(message)
    author = blank_to_nil(author)

    case {text, message} do
      {nil, nil} -> nil
      {nil, message} -> "Replying to #{message}."
      {text, message} -> "#{reply_heading(author, message)}\n#{quote_text(text)}"
    end
  end

  defp reply_heading(nil, nil), do: "Replying to:"
  defp reply_heading(nil, message), do: "Replying to #{message}:"
  defp reply_heading(author, nil), do: "Replying to #{author}:"
  defp reply_heading(author, message), do: "Replying to #{author} in #{message}:"

  defp quote_text(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", &("> " <> &1))
  end

  defp attachment_sections(attachments) when is_list(attachments) do
    Enum.reduce_while(attachments, {:ok, []}, fn attachment, {:ok, acc} ->
      case attachment_section(Attachment.normalize(attachment)) do
        {:ok, section} -> {:cont, {:ok, [section | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, sections} -> {:ok, Enum.reverse(sections)}
      {:error, _reason} = error -> error
    end
  end

  defp attachment_section(%Attachment{url: url} = attachment) when is_binary(url) and url != "" do
    label = attachment_label(attachment, url)

    section =
      case attachment.kind do
        :image -> "![#{escape_markdown_label(label)}](#{url})"
        _ -> "[#{escape_markdown_label(label)}](#{url})"
      end

    {:ok, section}
  end

  defp attachment_section(%Attachment{}),
    do: {:error, {:unsupported_file_upload, :github_requires_public_url}}

  defp attachment_label(%Attachment{} = attachment, url) do
    attachment.metadata[:alt_text] ||
      attachment.metadata["alt_text"] ||
      attachment.filename ||
      filename_from_url(url) ||
      "attachment"
  end

  defp media_from_markdown(nil), do: []
  defp media_from_markdown(""), do: []

  defp media_from_markdown(markdown) when is_binary(markdown) do
    images =
      ~r/!\[([^\]]*)\]\((https?:\/\/[^)\s]+)(?:\s+"[^"]*")?\)/
      |> Regex.scan(markdown)
      |> Enum.map(fn [_match, alt, url] ->
        Media.new(%{
          kind: :image,
          url: url,
          filename: filename_from_url(url),
          metadata: %{"alt_text" => alt}
        })
      end)

    linked_files =
      ~r/(?<!!)\[([^\]]+)\]\((https?:\/\/[^)\s]+)(?:\s+"[^"]*")?\)/
      |> Regex.scan(markdown)
      |> Enum.map(fn [_match, label, url] ->
        Media.new(%{url: url, filename: label || filename_from_url(url)})
      end)

    images ++ linked_files
  end

  defp github_reaction(emoji) do
    normalized =
      emoji
      |> to_string()
      |> String.trim()
      |> String.trim(":")
      |> String.downcase()

    case Map.fetch(@github_reactions, normalized) do
      {:ok, content} -> {:ok, content}
      :error -> {:error, {:unsupported_reaction, normalized}}
    end
  end

  defp reaction_id(target, message_id, content, opts) do
    case Keyword.get(opts, :reaction_id) do
      reaction_id when reaction_id not in [nil, ""] ->
        {:ok, reaction_id}

      _ ->
        find_reaction_id(target, message_id, content, opts)
    end
  end

  defp find_reaction_id(target, message_id, content, opts) do
    with {:ok, reactions} <- list_reactions(target, message_id, opts) do
      reactions
      |> Enum.find(&(Map.get(&1, "content") == content and reaction_user_matches?(&1, opts)))
      |> reaction_id_from_match(content)
    end
  end

  defp reaction_id_from_match(%{"id" => id}, _content), do: {:ok, id}
  defp reaction_id_from_match(_reaction, content), do: {:error, {:reaction_not_found, content}}

  defp list_reactions(target, message_id, opts) do
    case reaction_target(opts) do
      :issue ->
        transport(opts).list_issue_reactions(
          target.owner,
          target.repo,
          target.issue_number,
          opts
        )

      :comment ->
        transport(opts).list_issue_comment_reactions(target.owner, target.repo, message_id, opts)
    end
  end

  defp reaction_user_matches?(reaction, opts) do
    case Keyword.get(opts, :user_login) do
      user_login when user_login in [nil, ""] -> true
      user_login -> get_in(reaction, ["user", "login"]) == user_login
    end
  end

  defp reaction_target(opts) do
    case Keyword.get(opts, :target, Keyword.get(opts, :target_type, :comment)) do
      value when value in [:issue, "issue"] -> :issue
      _ -> :comment
    end
  end

  defp open_thread_room_id(room_or_repo_id, issue_number) do
    case parse_room_id(room_or_repo_id) do
      {:ok, _target} ->
        {:ok, room_or_repo_id}

      {:error, _reason} ->
        with {:ok, repo} <- parse_repo_id(room_or_repo_id),
             {:ok, issue_number} <- parse_issue_number(issue_number) do
          {:ok, "#{repo.owner}/#{repo.repo}##{issue_number}"}
        end
    end
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

  defp parse_repo_id(repo_id) when is_binary(repo_id) do
    case Regex.run(~r{\A([^/\s]+)/([^#\s]+)(?:#\d+)?\z}, repo_id) do
      [_, owner, repo] -> {:ok, %{owner: owner, repo: repo}}
      _ -> {:error, :invalid_repo_id}
    end
  end

  defp parse_repo_id(_), do: {:error, :invalid_repo_id}

  defp parse_issue_number(value) when is_integer(value), do: {:ok, value}

  defp parse_issue_number(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> {:ok, number}
      _ -> {:error, :invalid_issue_number}
    end
  end

  defp parse_issue_number(_value), do: {:error, :invalid_issue_number}

  defp pull_request_issue?(%{"pull_request" => pull_request}) when is_map(pull_request),
    do: true

  defp pull_request_issue?(_issue), do: false

  defp filename_from_url(url) when is_binary(url) do
    url
    |> URI.parse()
    |> Map.get(:path)
    |> case do
      nil -> nil
      "" -> nil
      path -> path |> Path.basename() |> URI.decode()
    end
  rescue
    _ -> nil
  end

  defp filename_from_url(_url), do: nil

  defp escape_markdown_label(label) do
    label
    |> to_string()
    |> String.replace("[", "\\[")
    |> String.replace("]", "\\]")
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value) when is_binary(value), do: value
  defp blank_to_nil(value), do: to_string(value)

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
