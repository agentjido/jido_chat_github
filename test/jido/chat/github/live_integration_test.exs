defmodule Jido.Chat.GitHub.LiveIntegrationTest do
  use ExUnit.Case, async: false

  alias Jido.Chat.GitHub.Adapter
  alias Jido.Chat.PostPayload

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

      payload =
        PostPayload.new(%{
          kind: :markdown,
          markdown: "#{text} rich",
          files: [
            %{
              kind: :image,
              url: "https://github.githubassets.com/images/modules/logos_page/GitHub-Mark.png",
              filename: "GitHub-Mark.png"
            }
          ]
        })

      assert {:ok, rich} =
               Adapter.post_message(
                 room_id,
                 payload,
                 Keyword.merge(opts, reply_to_id: sent.external_message_id)
               )

      assert :ok = Adapter.add_reaction(room_id, rich.external_message_id, "rocket", opts)
      assert :ok = Adapter.remove_reaction(room_id, rich.external_message_id, "rocket", opts)

      assert :ok = Adapter.delete_message(room_id, rich.external_message_id, opts)
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
