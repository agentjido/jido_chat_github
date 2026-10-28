defmodule Jido.Chat.GitHub.Adapter do
  @moduledoc "Stateless GitHub Issues adapter for Jido Chat."
  use Jido.Chat.Adapter

  alias Jido.Chat.GitHub
  alias Jido.Chat.GitHub.{Normalizer, Operations, Transport.ReqClient}
  alias Jido.Chat.Operations.Definitions

  @native [
    :send_message,
    :edit_message,
    :delete_message,
    :fetch_message,
    :fetch_messages,
    :get_user
  ]

  @impl true
  def channel_type, do: :github

  @impl true
  def default_transport, do: ReqClient

  @impl true
  def event_definitions, do: GitHub.event_definitions()

  @impl true
  def capabilities do
    Map.new(Definitions.all(), fn {_, {_, operation, _, _, _}} ->
      {operation, if(operation in @native, do: :native, else: :unsupported)}
    end)
  end

  @impl true
  def invoke(client, request, opts) do
    case Definitions.lookup(request.type) do
      {_, operation, _, _, _} ->
        Operations.invoke(operation, client, request, opts)

      _ ->
        {:error, {:not_attempted, :unsupported}}
    end
  end

  @impl true
  def normalize(client, input, _opts), do: Normalizer.normalize(client, input)
end
