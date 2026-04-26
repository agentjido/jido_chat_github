defmodule Jido.Chat.GitHub.LiveIntegrationTest do
  use ExUnit.Case, async: false

  alias Jido.Chat.GitHub.Adapter

  @moduletag :live

  test "creates, fetches, edits, and deletes a live issue comment" do
    token = System.get_env("GITHUB_TOKEN")
    room_id = System.get_env("GITHUB_TEST_ISSUE")

    if run_live?(token, room_id) do
      text = "jido github live #{System.system_time(:millisecond)}"
      opts = [token: token]

      assert {:ok, sent} = Adapter.send_message(room_id, text, opts)

      assert {:ok, fetched} = Adapter.fetch_message(room_id, sent.external_message_id, opts)

      assert fetched.text == text

      edited = text <> " edited"

      assert {:ok, _} =
               Adapter.edit_message(
                 room_id,
                 sent.external_message_id,
                 edited,
                 opts
               )

      assert :ok = Adapter.delete_message(room_id, sent.external_message_id, opts)
    else
      refute run_live?(token, room_id)
    end
  end

  defp run_live?(token, room_id) do
    System.get_env("RUN_LIVE_GITHUB_TESTS") in ["1", "true", "TRUE", "yes"] and
      token not in [nil, ""] and room_id not in [nil, ""]
  end
end
