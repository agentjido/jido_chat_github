defmodule Jido.Chat.GitHub.Normalizer do
  @moduledoc false

  alias Jido.Chat.{Client, Delivery}
  alias Jido.Chat.Signal.{Identity, MessageReceived, MessageUpdated, NormalizationFailed, Policy}

  def normalize(%Client{} = client, input) when is_map(input) or is_list(input) do
    items = if is_list(input), do: input, else: [input]
    delivery_id = "github:" <> digest({client.id, items})

    with {:ok, signals} <- map_items(client, delivery_id, items),
         do: Delivery.new(client, delivery_id, signals)
  rescue
    _ -> Policy.error(:invalid_delivery)
  catch
    _, _ -> Policy.error(:invalid_delivery)
  end

  def normalize(_, _), do: Policy.error(:invalid_delivery)

  defp map_items(client, delivery_id, items) do
    items
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {item, index}, {:ok, acc} ->
      case map_item(client, delivery_id, item, index) do
        {:ok, signal} -> {:cont, {:ok, acc ++ [signal]}}
        error -> {:halt, error}
      end
    end)
  end

  defp map_item(client, delivery_id, item, index) when is_map(item) do
    comment = item["comment"]
    issue = item["issue"]
    repo = item["repository"] || %{}
    action = item["action"] || "created"
    room_id = room(repo, issue)

    if comment_event?(comment, room_id, action) do
      comment_signal(client, delivery_id, item, comment, issue, action, room_id)
    else
      failure(client, delivery_id, item, index, room_id)
    end
  end

  defp map_item(client, delivery_id, item, index),
    do: failure(client, delivery_id, item, index, nil)

  defp comment_event?(comment, room_id, action),
    do: is_map(comment) and is_binary(room_id) and action in ["created", "edited"]

  defp comment_signal(client, delivery_id, item, comment, issue, action, room_id) do
    definition = if action == "edited", do: MessageUpdated, else: MessageReceived

    data =
      %{
        "item_id" => item_id(item),
        "delivery_id" => delivery_id,
        "room_id" => room_id,
        "message_id" => identifier(comment["id"]),
        "sender" => actor(comment["user"] || item["sender"]),
        "text" => comment["body"] || ""
      }
      |> optional("timestamp", comment["updated_at"] || comment["created_at"])
      |> maybe_received(definition, issue)

    signal(client, definition, room_id, data)
  end

  defp maybe_received(data, MessageReceived, issue) do
    data
    |> Map.put("conversation_kind", "thread")
    |> optional("conversation_name", issue && issue["title"])
  end

  defp maybe_received(data, _, _), do: data

  defp failure(client, delivery_id, item, index, room_id) do
    data =
      %{
        "item_id" => item_id(item),
        "delivery_id" => delivery_id,
        "code" => "unsupported_item",
        "item_index" => index,
        "provider_kind" => "github_webhook"
      }
      |> optional("room_id", room_id)

    signal(client, NormalizationFailed, room_id, data)
  end

  defp signal(client, definition, room_id, data) do
    subject = if is_binary(room_id), do: Identity.conversation_subject(client.id, room_id)
    definition.new(data, source: client.source, subject: subject)
  end

  defp room(%{"full_name" => full_name}, %{"number" => number})
       when is_binary(full_name) and not is_nil(number),
       do: full_name <> "#" <> to_string(number)

  defp room(_, _), do: nil

  defp actor(%{"id" => id} = user),
    do: %{"id" => identifier(id)} |> optional("username", user["login"])

  defp actor(_), do: %{"id" => "unknown"}
  defp item_id(item), do: "github:item:" <> digest(item)
  defp identifier(nil), do: nil
  defp identifier(value), do: to_string(value)
  defp optional(map, _key, nil), do: map
  defp optional(map, key, value), do: Map.put(map, key, value)

  defp digest(value) do
    :crypto.hash(:sha256, :erlang.term_to_binary(value, [:deterministic]))
    |> Base.url_encode64(padding: false)
  end
end
