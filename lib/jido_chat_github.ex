defmodule Jido.Chat.GitHub do
  @moduledoc "GitHub Issues adapter package for `Jido.Chat`."

  alias Jido.Chat.GitHub.Adapter

  @doc "Returns the canonical GitHub adapter module."
  def adapter, do: Adapter
end
