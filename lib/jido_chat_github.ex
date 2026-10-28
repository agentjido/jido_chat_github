defmodule Jido.Chat.GitHub do
  @moduledoc "GitHub Issues adapter package for `Jido.Chat`."

  alias Jido.Chat.GitHub.Adapter

  @doc "Returns the canonical GitHub adapter module."
  def adapter, do: Adapter

  @doc "Returns the incoming facts normalized by GitHub."
  def event_definitions do
    [
      Jido.Chat.Signal.MessageReceived,
      Jido.Chat.Signal.MessageUpdated,
      Jido.Chat.Signal.NormalizationFailed
    ]
  end
end
