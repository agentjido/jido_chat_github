defmodule Jido.Chat.GitHub.LiveIntegrationTest do
  use ExUnit.Case, async: false

  alias Jido.Chat.Client
  alias Jido.Chat.GitHub.Adapter
  alias Jido.Chat.Signal.{FetchMessage, Policy}

  @moduletag :live
  @run_live System.get_env("RUN_LIVE_GITHUB_TESTS") in ["1", "true", "TRUE", "yes"]

  if not @run_live do
    @moduletag skip: "set RUN_LIVE_GITHUB_TESTS=true to run live GitHub tests"
  end

  if @run_live and
       Enum.any?(~w(GITHUB_TOKEN GITHUB_TEST_ISSUE), &(System.get_env(&1) in [nil, ""])) do
    raise "live GitHub tests require GITHUB_TOKEN and GITHUB_TEST_ISSUE"
  end

  test "creates, fetches, edits, and deletes a live issue comment" do
    token = System.fetch_env!("GITHUB_TOKEN")
    room_id = System.fetch_env!("GITHUB_TEST_ISSUE")

    client =
      Client.new!(Adapter,
        id: "github-live",
        credentials: %{token: token}
      )

    text = "jido github live #{System.system_time(:millisecond)}"
    assert {:ok, sent} = Jido.Chat.send_text(client, room_id, text)
    id = sent.data["result"]["id"]
    assert {:ok, fetched} = fetch_message(client, room_id, id)
    assert fetched.data["result"]["text"] == text
    assert {:ok, _} = Jido.Chat.edit_message(client, room_id, id, text <> " edited")
    assert {:ok, _} = Jido.Chat.delete_message(client, room_id, id)
  end

  defp fetch_message(client, room_id, message_id) do
    request =
      Policy.new!(FetchMessage, %{
        "client_id" => client.id,
        "request_id" => "github-live:fetch",
        "room_id" => room_id,
        "message_id" => message_id
      })

    Jido.Chat.execute(client, request)
  end
end
