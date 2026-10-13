defmodule Jido.Chat.GitHub.Adapter do
  @moduledoc "GitHub Issues `Jido.Chat.Adapter` implementation."
  use Jido.Chat.Adapter

  alias Jido.Chat.Delivery
  alias Jido.Chat.Errors.Contract
  alias Jido.Chat.Signal.Identity
  alias Jido.Chat.Signal.Policy

  alias Jido.Chat.Signal.{
    MessageReceived,
    MessageUpdated,
    ReactionAdded,
    ReactionRemoved,
    ThreadChanged,
    ThreadStarted
  }

  alias Jido.Chat.{
    Attachment,
    Author,
    FileUpload,
    Media,
    Message,
    MessagePage,
    MessageSubject,
    PostPayload,
    Thread,
    ThreadPage,
    ThreadSummary,
    UserInfo,
    WebhookRequest,
    WebhookResponse
  }

  alias Jido.Chat.GitHub.Transport.ReqClient

  @github_reactions %{
    "+1" => "+1",
    "thumbsup" => "+1",
    "thumbs_up" => "+1",
    <<128_077::utf8>> => "+1",
    "-1" => "-1",
    "thumbsdown" => "-1",
    "thumbs_down" => "-1",
    <<128_078::utf8>> => "-1",
    "laugh" => "laugh",
    "smile" => "laugh",
    <<128_516::utf8>> => "laugh",
    "confused" => "confused",
    <<128_533::utf8>> => "confused",
    "heart" => "heart",
    <<10_084::utf8>> => "heart",
    <<10_084::utf8, 65_039::utf8>> => "heart",
    "hooray" => "hooray",
    "tada" => "hooray",
    <<127_881::utf8>> => "hooray",
    "rocket" => "rocket",
    <<128_640::utf8>> => "rocket",
    "eyes" => "eyes",
    <<128_064::utf8>> => "eyes"
  }
  @image_media_types %{
    ".avif" => "image/avif",
    ".bmp" => "image/bmp",
    ".gif" => "image/gif",
    ".jpeg" => "image/jpeg",
    ".jpg" => "image/jpeg",
    ".png" => "image/png",
    ".svg" => "image/svg+xml",
    ".tif" => "image/tiff",
    ".tiff" => "image/tiff",
    ".webp" => "image/webp"
  }
  @invalid_percent_encoding ~r/%(?![0-9A-Fa-f]{2})/
  @comment_page_size 100
  @max_comment_pages 1000
  @impl true
  def channel_type do
    :github
  end

  @impl true
  def capabilities do
    %{
      send_message: :native,
      edit_message: :native,
      delete_message: :native,
      fetch_thread: :native,
      fetch_message: :native,
      get_user: :native,
      fetch_subject: :native,
      get_thread_participants: :native,
      mark_as_read: :unsupported,
      fetch_messages: :native,
      list_threads: :native,
      open_thread: :native,
      post_message: :native,
      post_channel_message: :native,
      webhook: :native,
      verify_webhook: :native,
      normalize_event: :native,
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

  defp provider_message(%{"comment" => comment, "issue" => issue, "repository" => repo} = payload) do
    {:ok, incoming_from_comment(comment, issue, repo, payload)}
  end

  defp provider_message(%{"issue" => issue, "repository" => repo} = payload) do
    {:ok, incoming_from_issue(issue, repo, payload)}
  end

  defp provider_message(_) do
    {:error, :unsupported_payload}
  end

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
      {:ok, target} -> post_thread_payload(room_id, target, payload, opts)
      {:error, _reason} -> post_repo_payload(room_id, payload, opts)
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
  def get_user(user_id, opts \\ []) do
    with {:ok, user} <- transport(opts).get_user(user_id, opts) do
      {:ok, user_info(user)}
    end
  end

  @impl true
  def fetch_subject(room_id, opts \\ []) do
    with {:ok, target} <- parse_thread_target(room_id, opts),
         {:ok, issue} <-
           transport(opts).get_issue(target.owner, target.repo, target.issue_number, opts) do
      {:ok, message_subject(issue, target)}
    end
  end

  @impl true
  def get_thread_participants(room_id, opts \\ []) do
    with {:ok, target} <- parse_thread_target(room_id, opts),
         {:ok, issue} <-
           transport(opts).get_issue(target.owner, target.repo, target.issue_number, opts),
         {:ok, comments} <- list_all_issue_comments(target, opts) do
      participants =
        [issue["user"] | List.wrap(issue["assignees"])]
        |> Kernel.++(Enum.map(comments, & &1["user"]))
        |> Enum.filter(&valid_github_user?/1)
        |> Enum.uniq_by(&github_user_key/1)
        |> Enum.map(&user_info/1)

      {:ok, participants}
    end
  end

  defp query_page(opts) do
    page = Keyword.get(opts, :cursor, Keyword.get(opts, :page, 1))
    page = if is_binary(page), do: Integer.parse(page), else: {page, ""}
    limit = Keyword.get(opts, :limit, Keyword.get(opts, :per_page, 30))

    case page do
      {value, ""}
      when is_integer(value) and value > 0 and is_integer(limit) and limit in 1..100 ->
        {:ok, opts |> Keyword.put(:page, value) |> Keyword.put(:per_page, limit)}

      _ ->
        {:error, :invalid_query_cursor}
    end
  end

  defp next_page(items, opts) do
    if length(items) == opts[:per_page], do: to_string(opts[:page] + 1), else: nil
  end

  defp list_all_issue_comments(target, opts) do
    list_all_issue_comments(target, opts, 1, [])
  end

  defp list_all_issue_comments(_target, _opts, page, _comments) when page > @max_comment_pages do
    {:error, :github_comment_page_limit_exceeded}
  end

  defp list_all_issue_comments(target, opts, page, comments) do
    page_opts = opts |> Keyword.put(:per_page, @comment_page_size) |> Keyword.put(:page, page)

    case transport(opts).list_issue_comments(
           target.owner,
           target.repo,
           target.issue_number,
           page_opts
         ) do
      {:ok, page_comments} when is_list(page_comments) ->
        all_comments = [page_comments | comments]

        if length(page_comments) < @comment_page_size do
          {:ok, all_comments |> Enum.reverse() |> List.flatten()}
        else
          list_all_issue_comments(target, opts, page + 1, all_comments)
        end

      {:ok, _response} ->
        {:error, :invalid_issue_comments_response}

      {:error, _reason} = error ->
        error
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
         {:ok, opts} <- query_page(opts),
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
         next_cursor: next_page(comments, opts),
         metadata: %{"raw" => comments}
       })}
    end
  end

  @impl true
  def list_threads(repo_id, opts \\ []) do
    with {:ok, target} <- parse_repo_id(repo_id),
         {:ok, opts} <- query_page(opts),
         {:ok, issues} <- transport(opts).list_issues(target.owner, target.repo, opts) do
      threads =
        issues
        |> Enum.reject(&pull_request_issue?/1)
        |> Enum.map(&thread_summary_from_issue(&1, target))

      {:ok,
       ThreadPage.new(%{
         threads: threads,
         next_cursor: next_page(issues, opts),
         metadata: %{"raw" => issues}
       })}
    end
  end

  @impl true
  def fetch_channel_messages(repo_id, opts \\ []) do
    with {:ok, target} <- parse_repo_id(repo_id),
         {:ok, opts} <- query_page(opts),
         {:ok, issues} <- transport(opts).list_issues(target.owner, target.repo, opts) do
      messages =
        issues
        |> Enum.reject(&pull_request_issue?/1)
        |> Enum.map(&issue_message_from_issue(&1, target))

      {:ok,
       MessagePage.new(%{
         messages: messages,
         next_cursor: next_page(issues, opts),
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
  def verify_webhook(request, opts \\ [])

  def verify_webhook(%WebhookRequest{} = request, opts) do
    secret =
      if Keyword.has_key?(opts, :webhook_secret),
        do: opts[:webhook_secret],
        else: System.get_env("GITHUB_WEBHOOK_SECRET")

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
    request |> WebhookRequest.new() |> verify_webhook(opts)
  end

  @impl true
  def format_webhook_response({:ok, %Delivery{}}, _opts), do: WebhookResponse.accepted()

  def format_webhook_response({:error, %Contract{code: code}}, _opts),
    do: WebhookResponse.error(400, Atom.to_string(code))

  def format_webhook_response(_, _opts), do: WebhookResponse.error(400, "rejected")

  defp incoming_from_comment(comment, issue, repo, payload) do
    room_id = room_id(repo, issue)
    user = comment["user"] || %{}

    %{
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
    }
  end

  defp incoming_from_issue(issue, repo, payload) do
    room_id = room_id(repo, issue)
    user = issue["user"] || %{}

    %{
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
    }
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
    %{
      external_message_id: to_string(comment["id"]),
      external_room_id: room_id,
      timestamp: comment["created_at"],
      channel_type: :github,
      status: status,
      raw: comment,
      metadata: %{"html_url" => comment["html_url"]}
    }
  end

  defp response_from_issue(issue, target, status \\ :sent) do
    room_id = "#{target.owner}/#{target.repo}##{issue["number"]}"

    %{
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
    }
  end

  defp put_response_metadata(%{} = response, key, value) do
    %{response | metadata: Map.put(response.metadata || %{}, key, value)}
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

  defp user_info(user) do
    UserInfo.new(%{
      id: user["id"] || user["node_id"] || user["login"],
      username: user["login"],
      display_name: user["name"] || user["login"],
      email: user["email"],
      avatar_url: user["avatar_url"],
      is_bot: user["type"] == "Bot",
      metadata: %{"html_url" => user["html_url"], "type" => user["type"], "raw" => user}
    })
  end

  defp message_subject(issue, target) do
    MessageSubject.new(%{
      type:
        if pull_request_issue?(issue) do
          :pull_request
        else
          :issue
        end,
      id: issue["number"] || issue["id"] || issue["node_id"],
      title: issue["title"],
      url: issue["html_url"],
      status: issue["state"],
      metadata: %{
        "repository" => "#{target.owner}/#{target.repo}",
        "issue_number" => issue["number"] || target.issue_number,
        "locked" => issue["locked"] || false,
        "labels" => Enum.map(issue["labels"] || [], &github_label_name/1),
        "raw" => issue
      }
    })
  end

  defp github_label_name(%{"name" => name}), do: name
  defp github_label_name(name) when is_binary(name), do: name
  defp github_label_name(label), do: label

  defp valid_github_user?(user) when is_map(user),
    do: not is_nil(user["id"] || user["node_id"] || user["login"])

  defp valid_github_user?(_user), do: false
  defp github_user_key(user), do: user["id"] || user["node_id"] || user["login"]
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
      root_message: provider_result_message(incoming),
      metadata: %{"issue" => issue}
    })
  end

  defp render_text_body(text, opts) do
    text |> to_string() |> sections_with_reply(opts, []) |> render_sections()
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

  defp metadata_value(metadata, key) when is_map(metadata) do
    Map.get(metadata, key) || Map.get(metadata, to_string(key))
  end

  defp metadata_value(_metadata, _key) do
    nil
  end

  defp sections_with_reply(base, opts, extra_sections) do
    [reply_section(opts), blank_to_nil(base) | extra_sections]
  end

  defp render_sections(sections) do
    body = sections |> Enum.reject(&is_nil/1) |> Enum.join("\n\n") |> String.trim()

    if body == "" do
      {:error, :empty_message}
    else
      {:ok, body}
    end
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
      {text, message} -> "#{reply_heading(author, message)}
#{quote_text(text)}"
    end
  end

  defp reply_heading(nil, nil) do
    "Replying to:"
  end

  defp reply_heading(nil, message) do
    "Replying to #{message}:"
  end

  defp reply_heading(author, nil) do
    "Replying to #{author}:"
  end

  defp reply_heading(author, message) do
    "Replying to #{author} in #{message}:"
  end

  defp quote_text(text) do
    text |> String.split("\n") |> Enum.map_join("\n", &("> " <> &1))
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

  defp attachment_section(%Attachment{}) do
    {:error, {:unsupported_file_upload, :github_requires_public_url}}
  end

  defp attachment_label(%Attachment{} = attachment, url) do
    attachment.metadata[:alt_text] || attachment.metadata["alt_text"] || attachment.filename ||
      filename_from_url(url) || "attachment"
  end

  defp media_from_markdown(nil) do
    []
  end

  defp media_from_markdown("") do
    []
  end

  defp media_from_markdown(markdown) when is_binary(markdown) do
    images =
      ~r/!\[([^\]]*)\]\((https?:\/\/[^)\s]+)(?:\s+"[^"]*")?\)/
      |> Regex.scan(markdown)
      |> Enum.map(fn [_match, alt, url] ->
        Media.new(%{
          kind: :image,
          url: url,
          filename: filename_from_url(url),
          media_type: image_media_type_from_url(url),
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

  defp image_media_type_from_url(url) do
    case filename_from_url(url) do
      filename when is_binary(filename) ->
        filename |> Path.extname() |> String.downcase() |> then(&Map.get(@image_media_types, &1))

      _other ->
        nil
    end
  end

  defp github_reaction(emoji) do
    normalized = emoji |> to_string() |> String.trim() |> String.trim(":") |> String.downcase()

    case Map.fetch(@github_reactions, normalized) do
      {:ok, content} -> {:ok, content}
      :error -> {:error, {:unsupported_reaction, normalized}}
    end
  end

  defp reaction_id(target, message_id, content, opts) do
    case Keyword.get(opts, :reaction_id) do
      reaction_id when reaction_id not in [nil, ""] -> {:ok, reaction_id}
      _ -> find_reaction_id(target, message_id, content, opts)
    end
  end

  defp find_reaction_id(target, message_id, content, opts) do
    with {:ok, reactions} <- list_reactions(target, message_id, opts) do
      reactions
      |> Enum.find(&(Map.get(&1, "content") == content and reaction_user_matches?(&1, opts)))
      |> reaction_id_from_match(content)
    end
  end

  defp reaction_id_from_match(%{"id" => id}, _content) do
    {:ok, id}
  end

  defp reaction_id_from_match(_reaction, content) do
    {:error, {:reaction_not_found, content}}
  end

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
        with {:ok, target} <- parse_repo_thread_target(room_or_repo_id, issue_number) do
          {:ok, "#{target.owner}/#{target.repo}##{target.issue_number}"}
        end
    end
  end

  defp room_id(repo, issue) do
    "#{repo["owner"]["login"]}/#{repo["name"]}##{issue["number"]}"
  end

  defp thread_id(room_id) do
    "github:#{room_id}"
  end

  defp parse_room_id(room_id) when is_binary(room_id) do
    case Regex.run(~r{\A([^/\s]+)/([^#\s]+)#(\d+)\z}, room_id) do
      [_, owner, repo, issue_number] ->
        {:ok, %{owner: owner, repo: repo, issue_number: String.to_integer(issue_number)}}

      _ ->
        {:error, :invalid_room_id}
    end
  end

  defp parse_room_id(_) do
    {:error, :invalid_room_id}
  end

  defp parse_thread_target(room_id, opts) do
    case parse_room_id(room_id) do
      {:ok, target} ->
        {:ok, target}

      {:error, :invalid_room_id} ->
        parse_repo_thread_target(
          room_id,
          opts[:issue_number] || opts[:thread_id] || opts[:external_thread_id]
        )
    end
  end

  defp parse_repo_thread_target(repo_id, issue_number) do
    with {:ok, repo} <- parse_repo_id(repo_id),
         {:ok, issue_number} <- parse_issue_number(issue_number) do
      {:ok, Map.put(repo, :issue_number, issue_number)}
    end
  end

  defp parse_repo_id(repo_id) when is_binary(repo_id) do
    case Regex.run(~r{\A([^/\s]+)/([^#\s]+)(?:#\d+)?\z}, repo_id) do
      [_, owner, repo] -> {:ok, %{owner: owner, repo: repo}}
      _ -> {:error, :invalid_repo_id}
    end
  end

  defp parse_repo_id(_) do
    {:error, :invalid_repo_id}
  end

  defp parse_issue_number(value) when is_integer(value) do
    {:ok, value}
  end

  defp parse_issue_number(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> {:ok, number}
      _ -> {:error, :invalid_issue_number}
    end
  end

  defp parse_issue_number(_value) do
    {:error, :invalid_issue_number}
  end

  defp pull_request_issue?(%{"pull_request" => pull_request}) when is_map(pull_request) do
    true
  end

  defp pull_request_issue?(_issue) do
    false
  end

  defp filename_from_url(url) when is_binary(url) do
    url
    |> URI.parse()
    |> Map.get(:path)
    |> case do
      nil ->
        nil

      "" ->
        nil

      path ->
        if Regex.match?(@invalid_percent_encoding, path) do
          nil
        else
          path |> Path.basename() |> URI.decode()
        end
    end
  rescue
    _ -> nil
  end

  defp filename_from_url(_url) do
    nil
  end

  defp escape_markdown_label(label) do
    label |> to_string() |> String.replace("[", "\\[") |> String.replace("]", "\\]")
  end

  defp blank_to_nil(nil) do
    nil
  end

  defp blank_to_nil("") do
    nil
  end

  defp blank_to_nil(value) when is_binary(value) do
    value
  end

  defp blank_to_nil(value) do
    to_string(value)
  end

  defp transport(opts) do
    Keyword.get(opts, :transport, ReqClient)
  end

  defp raw_body(%WebhookRequest{raw: raw}) when is_binary(raw) do
    raw
  end

  defp raw_body(%WebhookRequest{metadata: %{"raw_body" => raw}}) when is_binary(raw) do
    raw
  end

  defp raw_body(%WebhookRequest{metadata: %{raw_body: raw}}) when is_binary(raw) do
    raw
  end

  defp raw_body(%WebhookRequest{payload: payload}) do
    Jason.encode!(payload)
  end

  defp hmac(secret, data) do
    :crypto.mac(:hmac, :sha256, secret, data) |> Base.encode16(case: :lower)
  end

  defp secure_compare(a, b) when byte_size(a) == byte_size(b) do
    :crypto.hash_equals(a, b)
  end

  defp secure_compare(_, _) do
    false
  end

  @impl true
  def signal_protocol, do: 1

  @impl true
  def normalize_event(binding, input) do
    tracker = {__MODULE__, make_ref()}
    Process.put(tracker, [])

    result =
      try do
        with {:ok, items} <- native_inputs(binding, input) do
          delivery = "github:delivery:" <> native_digest(Enum.map(items, &elem(&1, 2)))
          base = %{binding: binding, delivery: delivery, tracker: tracker}

          with {:ok, facts} <- native_items(base, items),
               do: Delivery.new(binding, delivery, facts)
        end
      rescue
        _ -> Policy.error(:invalid_delivery)
      catch
        _, _ -> Policy.error(:invalid_delivery)
      end

    if match?({:error, _}, result),
      do: Enum.each(Process.get(tracker, []), &Jido.Chat.cancel_resource(binding, &1))

    Process.delete(tracker)
    result
  end

  defp native_items(base, items) do
    items
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {{kind, payload, key}, index}, {:ok, acc} ->
      context = Map.merge(base, %{item: "github:item:" <> key, index: index})
      native_step(context, kind, payload, acc)
    end)
  end

  defp native_step(context, kind, payload, acc) do
    existing = Process.get(context.tracker)

    result =
      try do
        native_map(context, kind, payload)
      rescue
        _ -> {:error, :invalid_item}
      catch
        _, _ -> {:error, :invalid_item}
      end

    case result do
      {:ok, facts} ->
        facts = List.wrap(facts)

        if Enum.all?(facts, &(&1.type == "jido.chat.normalization.failed")),
          do:
            Enum.each(
              Process.get(context.tracker) -- existing,
              &Jido.Chat.cancel_resource(context.binding, &1)
            )

        {:cont, {:ok, acc ++ facts}}

      {:error, %Contract{code: code}} = error
      when code in [
             :signal_too_large,
             :delivery_too_large,
             :too_many_signals,
             :too_many_failures
           ] ->
        {:halt, error}

      _ ->
        Enum.each(
          Process.get(context.tracker) -- existing,
          &Jido.Chat.cancel_resource(context.binding, &1)
        )

        case native_failure(context, "invalid_item", kind, nil) do
          {:ok, fact} -> {:cont, {:ok, acc ++ [fact]}}
          error -> {:halt, error}
        end
    end
  end

  defp native_fact(context, definition, data, ordinal \\ "0") do
    room = data["room_id"]

    data =
      data
      |> Map.merge(%{
        "item_id" => context.item <> ":" <> definition.type() <> ":" <> ordinal,
        "delivery_id" => context.delivery
      })
      |> Map.reject(fn {key, value} ->
        is_nil(value) and key not in ["text", "previous", "current", "actor_id"]
      end)

    subject =
      if is_binary(room) and room != "",
        do: Identity.conversation_subject(context.binding.id, room)

    definition.new(data, source: context.binding.source, subject: subject)
  end

  defp native_failure(context, code, kind, room),
    do:
      native_fact(context, Jido.Chat.Signal.NormalizationFailed, %{
        "code" => code,
        "provider_kind" => kind,
        "item_index" => context.index,
        "room_id" => room
      })

  defp native_media(context, media) do
    Enum.reduce_while(media, {:ok, []}, fn value, {:ok, acc} ->
      case Jido.Chat.put_resource(context.binding, "media", value) do
        {:ok, ref} ->
          Process.put(context.tracker, [ref | Process.get(context.tracker)])

          item =
            %{"kind" => to_string(value.kind), "resource_ref" => ref}
            |> native_optional("name", value.filename)
            |> native_optional("media_type", value.media_type)

          {:cont, {:ok, acc ++ [item]}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp native_get(map, key) when is_map(map) do
    atom =
      try do
        String.to_existing_atom(key)
      rescue
        ArgumentError -> nil
      end

    if Map.has_key?(map, key), do: Map.get(map, key), else: Map.get(map, atom)
  end

  defp native_get(_, _), do: nil
  defp native_id(map, key), do: native_identifier(native_get(map, key))
  defp native_identifier(value) when is_binary(value) and value != "", do: value
  defp native_identifier(value) when is_integer(value), do: to_string(value)
  defp native_identifier(_), do: nil
  defp native_optional(map, _, nil), do: map
  defp native_optional(map, key, value), do: Map.put(map, key, value)
  defp native_time(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp native_time(value) when is_binary(value), do: value
  defp native_time(_), do: nil
  defp native_canonical(%_{} = value), do: value |> Map.from_struct() |> native_canonical()

  defp native_canonical(value) when is_map(value),
    do: value |> Enum.map(fn {k, v} -> {to_string(k), native_canonical(v)} end) |> Enum.sort()

  defp native_canonical(value) when is_list(value), do: Enum.map(value, &native_canonical/1)
  defp native_canonical(value), do: value

  defp native_digest(value),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(native_canonical(value), [:deterministic]))
      |> Base.url_encode64(padding: false)

  defp provider_result_message(incoming) do
    %{
      id: native_identifier(incoming.external_message_id),
      room_id: native_identifier(incoming.external_room_id),
      text: incoming.text,
      thread_id: Map.get(incoming, :external_thread_id),
      raw: Map.get(incoming, :raw),
      timestamp: Map.get(incoming, :timestamp),
      media: Map.get(incoming, :media, [])
    }
  end

  @impl true
  def configure_binding(opts) do
    {:ok,
     opts
     |> Keyword.put_new(:transport, ReqClient)
     |> Keyword.put_new(:token, System.get_env("GITHUB_TOKEN"))
     |> Keyword.put_new(:webhook_secret, System.get_env("GITHUB_WEBHOOK_SECRET"))}
  end

  defp native_inputs(binding, %WebhookRequest{} = request) do
    with :ok <- verify_webhook(request, binding.options) do
      kind = WebhookRequest.header(request, "x-github-event") || "unknown"
      id = WebhookRequest.header(request, "x-github-delivery") || native_digest(request.payload)
      {:ok, [{kind, request.payload, id}]}
    end
  end

  defp native_inputs(binding, items) when is_list(items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case native_inputs(binding, item) do
        {:ok, values} -> {:cont, {:ok, acc ++ values}}
        error -> {:halt, error}
      end
    end)
  end

  defp native_inputs(_binding, payload) when is_map(payload) do
    kind =
      cond do
        native_get(payload, "reaction") -> "reaction"
        native_get(payload, "comment") -> "issue_comment"
        native_get(payload, "issue") -> "issues"
        true -> native_get(payload, "type") || "unknown"
      end

    {:ok, [{kind, payload, native_digest(payload)}]}
  end

  defp native_inputs(_, _), do: Policy.error(:invalid_delivery)

  defp native_map(_context, "ping", _payload), do: {:ok, []}

  defp native_map(context, kind, payload),
    do: native_action(context, kind, native_get(payload, "action"), payload)

  defp native_action(context, "issue_comment", "created", payload),
    do: native_message(context, payload, MessageReceived)

  defp native_action(context, "issue_comment", "edited", payload),
    do: native_message(context, payload, MessageUpdated)

  defp native_action(context, "issues", "opened", payload) do
    with {:ok, thread} <- native_thread(context, payload, ThreadStarted, nil),
         {:ok, message} <- native_message(context, payload, MessageReceived),
         do: {:ok, [thread, message]}
  end

  defp native_action(context, "issues", "edited", payload) do
    with {:ok, thread} <- native_thread(context, payload, ThreadChanged, "updated"),
         {:ok, message} <- native_message(context, payload, MessageUpdated),
         do: {:ok, [thread, message]}
  end

  defp native_action(context, "issues", "reopened", payload),
    do: native_thread(context, payload, ThreadChanged, "reopened")

  defp native_action(context, "reaction", action, payload)
       when action in ["created", "deleted"] do
    issue = native_get(payload, "issue") || %{}
    repo = native_get(payload, "repository") || %{}
    reaction = native_get(payload, "reaction") || %{}
    comment = native_get(payload, "comment")
    definition = if action == "created", do: ReactionAdded, else: ReactionRemoved

    native_fact(context, definition, %{
      "room_id" => room_id(repo, issue),
      "message_id" => native_id(comment, "id") || native_id(issue, "number"),
      "actor_id" =>
        native_id(native_get(reaction, "user") || native_get(payload, "sender"), "id"),
      "reaction" => native_get(reaction, "content")
    })
  end

  defp native_action(context, kind, _action, _payload),
    do: native_failure(context, "unsupported_item", kind, nil)

  defp native_message(context, payload, definition) do
    with {:ok, incoming} <- provider_message(payload),
         {:ok, media} <- native_media(context, incoming.media) do
      user =
        native_get(native_get(payload, "comment") || native_get(payload, "issue"), "user") || %{}

      sender =
        %{
          "id" => native_id(user, "id") || native_id(user, "login"),
          "username" => native_get(user, "login"),
          "is_bot" => native_get(user, "type") == "Bot"
        }
        |> Map.reject(fn {_, v} -> is_nil(v) end)

      data = %{
        "room_id" => incoming.external_room_id,
        "message_id" => incoming.external_message_id,
        "thread_id" => incoming.external_thread_id,
        "text" => incoming.text,
        "sender" => sender,
        "media" => media,
        "timestamp" => native_time(incoming.timestamp)
      }

      native_fact(context, definition, data)
    end
  end

  defp native_thread(context, payload, definition, change) do
    issue = native_get(payload, "issue") || %{}
    repo = native_get(payload, "repository") || %{}

    data = %{
      "room_id" => room_id(repo, issue),
      "thread_id" => native_id(issue, "id") || native_id(issue, "number"),
      "parent_message_id" => native_id(issue, "number"),
      "actor_id" => native_id(native_get(payload, "sender") || native_get(issue, "user"), "id"),
      "name" => native_get(issue, "title")
    }

    data = if change, do: Map.put(data, "change", change), else: data
    native_fact(context, definition, data)
  end
end
