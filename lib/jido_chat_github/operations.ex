defmodule Jido.Chat.GitHub.Operations do
  @moduledoc false

  alias Jido.Chat.{Client, Signal}
  alias Jido.Chat.GitHub.Adapter

  def invoke(operation, %Client{adapter: Adapter} = client, request, opts) do
    call(operation, client, request.data, Keyword.merge(Client.options(client), opts))
  end

  def invoke(_, _, _, _), do: {:error, {:not_attempted, :unsupported}}

  defp call(:send_message, client, data, opts) do
    with {:ok, target} <- target(data["room_id"]),
         {:ok, raw} <-
           client.transport.create_issue_comment(
             target.owner,
             target.repo,
             target.number,
             data["text"],
             opts
           ) do
      message(raw, data["room_id"], "sent")
    end
  end

  defp call(:edit_message, client, data, opts) do
    with {:ok, target} <- target(data["room_id"]),
         {:ok, raw} <-
           client.transport.update_issue_comment(
             target.owner,
             target.repo,
             data["message_id"],
             data["text"],
             opts
           ) do
      message(raw, data["room_id"], "updated")
    end
  end

  defp call(:delete_message, client, data, opts) do
    with {:ok, target} <- target(data["room_id"]),
         :ok <-
           client.transport.delete_issue_comment(
             target.owner,
             target.repo,
             data["message_id"],
             opts
           ) do
      {:ok, %{"acknowledged" => true}}
    end
  end

  defp call(:fetch_message, client, data, opts) do
    with {:ok, target} <- target(data["room_id"]),
         {:ok, raw} <-
           client.transport.get_issue_comment(
             target.owner,
             target.repo,
             data["message_id"],
             opts
           ) do
      message(raw, data["room_id"], "received")
    end
  end

  defp call(:fetch_messages, client, data, opts) do
    with {:ok, target} <- target(data["room_id"]),
         {:ok, page} <- page(data),
         {:ok, raw} <-
           client.transport.list_issue_comments(
             target.owner,
             target.repo,
             target.number,
             Keyword.merge(opts, page)
           ),
         {:ok, messages} <- messages(raw, data["room_id"]) do
      complete = length(raw) < page[:per_page]
      next_cursor = if complete, do: nil, else: to_string(page[:page] + 1)
      {:ok, %{"messages" => messages, "next_cursor" => next_cursor, "complete" => complete}}
    end
  end

  defp call(:get_user, client, data, opts) do
    with {:ok, raw} <- client.transport.get_user(data["user_id"], opts) do
      {:ok,
       %{"id" => identifier(raw["id"] || raw["login"] || data["user_id"])}
       |> optional("username", raw["login"])
       |> optional("display_name", raw["name"])}
    end
  end

  defp call(_, _, _, _), do: {:error, {:not_attempted, :unsupported}}

  defp target(room_id) when is_binary(room_id) do
    case Regex.run(~r|^([^/]+)/([^#]+)#([1-9][0-9]*)$|, room_id) do
      [_, owner, repo, number] ->
        {:ok, %{owner: owner, repo: repo, number: String.to_integer(number)}}

      _ ->
        {:error, :invalid_room_id}
    end
  end

  defp target(_), do: {:error, :invalid_room_id}

  defp page(data) do
    with limit when is_integer(limit) and limit in 1..100 <- data["limit"] || 30,
         {page, ""} when page > 0 <- Integer.parse(data["cursor"] || "1") do
      {:ok, [per_page: limit, page: page]}
    else
      _ -> {:error, :invalid_query_cursor}
    end
  end

  defp messages(items, room_id) when is_list(items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case message(item, room_id, "received") do
        {:ok, result} -> {:cont, {:ok, acc ++ [result]}}
        error -> {:halt, error}
      end
    end)
  end

  defp messages(_, _), do: {:error, :invalid_provider_result}

  defp message(raw, room_id, status) when is_map(raw) do
    result =
      %{
        "id" => identifier(raw["id"]),
        "room_id" => room_id,
        "text" => raw["body"] || "",
        "status" => status
      }
      |> optional("sender", actor(raw["user"]))
      |> optional("timestamp", raw["updated_at"] || raw["created_at"])

    case Zoi.parse(Signal.Schemas.result(:message), result) do
      {:ok, checked} -> {:ok, checked}
      _ -> {:error, :invalid_provider_result}
    end
  end

  defp message(_, _, _), do: {:error, :invalid_provider_result}

  defp actor(%{"id" => id} = user),
    do: %{"id" => identifier(id)} |> optional("username", user["login"])

  defp actor(_), do: nil
  defp identifier(nil), do: nil
  defp identifier(value), do: to_string(value)
  defp optional(map, _key, nil), do: map
  defp optional(map, key, value), do: Map.put(map, key, value)
end
