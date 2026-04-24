defmodule Jido.Chat.GitHub.LiveIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :live

  @run_live System.get_env("RUN_LIVE_GITHUB_TESTS") in ["1", "true", "TRUE", "yes"]
  @token System.get_env("GITHUB_TOKEN")
  @room_id System.get_env("GITHUB_TEST_ISSUE")

  if @run_live and @token not in [nil, ""] and @room_id not in [nil, ""] do
    test "creates, fetches, edits, and deletes a live issue comment" do
      text = "jido github live #{System.system_time(:millisecond)}"
      opts = [token: @token]

      assert {:ok, sent} = Jido.Chat.GitHub.Adapter.send_message(@room_id, text, opts)

      assert {:ok, fetched} =
               Jido.Chat.GitHub.Adapter.fetch_message(@room_id, sent.external_message_id, opts)

      assert fetched.text == text

      edited = text <> " edited"

      assert {:ok, _} =
               Jido.Chat.GitHub.Adapter.edit_message(
                 @room_id,
                 sent.external_message_id,
                 edited,
                 opts
               )

      assert :ok =
               Jido.Chat.GitHub.Adapter.delete_message(@room_id, sent.external_message_id, opts)
    end
  else
    test "live GitHub tests require RUN_LIVE_GITHUB_TESTS, GITHUB_TOKEN, and GITHUB_TEST_ISSUE" do
      refute @run_live and @token not in [nil, ""] and @room_id not in [nil, ""]
    end
  end
end
