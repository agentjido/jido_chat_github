defmodule Jido.Chat.GitHub.ProtocolTest do
  use ExUnit.Case, async: false
  alias Jido.Chat.FileUpload
  alias Jido.Chat.Operations.Definitions
  alias Jido.Signal.Catalog
  alias Jido.Signal.Context
  alias Jido.Signal.Serialization
  alias Jido.Signal.Trace

  alias Jido.Chat.AdapterTestKit.Factories
  alias Jido.Chat.GitHub.Adapter
  alias Jido.Chat.WebhookRequest

  defmodule Transport do
    @behaviour Jido.Chat.GitHub.Transport
    @methods [
      create_issue_comment: 5,
      create_issue: 5,
      update_issue_comment: 5,
      delete_issue_comment: 4,
      get_user: 2,
      get_issue: 4,
      list_issue_comments: 4,
      get_issue_comment: 4,
      list_issues: 3,
      create_issue_reaction: 5,
      create_issue_comment_reaction: 5,
      list_issue_reactions: 4,
      list_issue_comment_reactions: 4,
      delete_issue_reaction: 5,
      delete_issue_comment_reaction: 5
    ]
    for {name, arity} <- @methods do
      args = Macro.generate_arguments(arity, __MODULE__)
      @impl true
      def unquote(name)(unquote_splicing(args)) do
        send(self(), {:provider, unquote(name), [unquote_splicing(args)]})

        if Process.get(:provider_failure),
          do: {:error, {:private, "private-token"}},
          else: result(unquote(name))
      end
    end

    defp user, do: %{"id" => 1, "login" => "user", "type" => "User"}
    defp comment, do: %{"id" => 123, "body" => "hello", "user" => user()}

    defp issue,
      do: %{
        "id" => 9,
        "number" => 42,
        "title" => "Title",
        "body" => "Body",
        "user" => user(),
        "assignees" => [user()]
      }

    defp result(:get_user), do: {:ok, user()}
    defp result(name) when name in [:get_issue, :create_issue], do: {:ok, issue()}

    defp result(name)
         when name in [:get_issue_comment, :create_issue_comment, :update_issue_comment],
         do: {:ok, comment()}

    defp result(:list_issue_comments), do: {:ok, [comment()]}
    defp result(:list_issues), do: {:ok, [issue()]}

    defp result(name) when name in [:list_issue_reactions, :list_issue_comment_reactions],
      do: {:ok, [%{"id" => 8, "content" => "+1"}]}

    defp result(name) when name in [:create_issue_reaction, :create_issue_comment_reaction],
      do: {:ok, %{"id" => 8}}

    defp result(_), do: :ok
  end

  @matrix Path.expand("../../../../../jido_chat/docs/migration/adapter-matrix.json", __DIR__)
          |> File.read!()
          |> Jason.decode!()
  @row Enum.find(@matrix["adapters"], &(&1["package"] == "jido_chat_github"))
  @calls %{
    send_message: [:create_issue_comment],
    send_file: [:create_issue_comment],
    post_message: [:create_issue_comment],
    edit_message: [:update_issue_comment],
    delete_message: [:delete_issue_comment],
    fetch_thread: [:get_issue],
    fetch_message: [:get_issue_comment],
    get_user: [:get_user],
    fetch_subject: [:get_issue],
    get_thread_participants: [:get_issue, :list_issue_comments],
    add_reaction: [:create_issue_comment_reaction],
    remove_reaction: [:list_issue_comment_reactions, :delete_issue_comment_reaction],
    post_channel_message: [:create_issue],
    stream: [:create_issue_comment, :update_issue_comment, :update_issue_comment],
    fetch_messages: [:list_issue_comments],
    fetch_channel_messages: [:list_issues],
    list_threads: [:list_issues],
    open_thread: [:get_issue]
  }
  setup do
    {:ok, binding} =
      Jido.Chat.bind(Adapter,
        id: "github-contract",
        transport: Transport,
        webhook_secret: "private-token"
      )

    %{binding: binding}
  end

  defp request(binding, operation, overrides \\ %{}) do
    room =
      if operation in [:post_channel_message, :list_threads, :fetch_channel_messages],
        do: "owner/repo",
        else: "owner/repo#42"

    extra = %{
      "room_id" => room,
      "message_id" => "123",
      "reaction" => "+1",
      "request_id" => "fixture:#{operation}"
    }

    # Only fields of the selected closed schema are sent.
    {_type, {_module, _, fields, _, _}} =
      Enum.find(Definitions.all(), fn {_, {_, op, _, _, _}} ->
        op == operation
      end)

    extra = Map.take(extra, ["request_id" | fields])

    extra =
      if operation == :send_file do
        {:ok, ref} =
          Jido.Chat.put_resource(
            binding,
            "file",
            FileUpload.new(%{url: "https://fixture.test/file", filename: "file.txt"})
          )

        Map.put(extra, "resource_ref", ref)
      else
        extra
      end

    Factories.operation_request(binding, operation, Map.merge(extra, overrides))
  end

  test "typed query cursors and private media keep complete results and scope", %{
    binding: binding
  } do
    for operation <- [:fetch_messages, :fetch_channel_messages, :list_threads] do
      parent = request(binding, operation, %{"cursor" => "2", "limit" => 1})
      assert {:ok, result} = Jido.Chat.execute(binding, parent)
      assert result.type == "jido.chat.operation.completed"
      assert result.data["result"]["next_cursor"] == "3"
      assert result.data["result"]["complete"] == false
      assert_receive {:provider, _, args}
      assert List.last(args)[:page] == 2 and List.last(args)[:per_page] == 1
      portable(result)
    end

    media_payload =
      put_in(payload("created", true), ["comment", "body"], "![image](https://fixture.test/file)")

    assert {:ok, %{signals: [fact]}} =
             Jido.Chat.normalize_event(binding, signed("issue_comment", media_payload))

    portable(fact)
    [item] = fact.data["media"]
    ref = item["resource_ref"]
    assert {:ok, media} = Jido.Chat.resolve_resource(binding, ref)
    assert media.url == "https://fixture.test/file"

    assert {:error, %{code: :resource_owner_mismatch}} =
             Task.async(fn -> Jido.Chat.resolve_resource(binding, ref) end) |> Task.await()

    {:ok, other} = Jido.Chat.bind(Adapter, id: "other")
    assert {:error, %{code: :invalid_resource}} = Jido.Chat.resolve_resource(other, ref)
    assert :ok = Jido.Chat.cancel_resource(binding, ref)
    assert {:error, %{code: :resource_cancelled}} = Jido.Chat.resolve_resource(binding, ref)
    {:ok, expired} = Jido.Chat.put_resource(binding, "media", media, ttl_ms: 0)
    assert {:error, %{code: :resource_expired}} = Jido.Chat.resolve_resource(binding, expired)
  end

  test "binding credentials remain captured when the environment changes" do
    previous = System.get_env("GITHUB_WEBHOOK_SECRET")

    on_exit(fn ->
      if previous,
        do: System.put_env("GITHUB_WEBHOOK_SECRET", previous),
        else: System.delete_env("GITHUB_WEBHOOK_SECRET")
    end)

    System.put_env("GITHUB_WEBHOOK_SECRET", "private-token")
    {:ok, binding} = Jido.Chat.bind(Adapter, id: "captured", transport: Transport)
    System.put_env("GITHUB_WEBHOOK_SECRET", "different")
    assert {:ok, unit} = Jido.Chat.normalize_event(binding, signed("ping", %{}))
    assert unit.signals == []
  end

  defp calls do
    receive do
      {:provider, name, _args} -> [name | calls()]
    after
      0 -> []
    end
  end

  defp portable(fact) do
    {:ok, json} = Serialization.serialize(fact)

    assert {:ok, ^fact} =
             Catalog.decode(
               Catalog.new!(Jido.Chat.signal_definitions()),
               json
             )

    refute json =~ "private-token"
    refute json =~ "\"url\":"
  end

  for {name, support} <- @row["operation_support"] do
    operation = String.to_atom(name)

    test "#{name} matches frozen #{support} with exact calls and cached native result", %{
      binding: binding
    } do
      operation = unquote(operation)

      assert Jido.Chat.Adapter.capabilities(Adapter)[operation] ==
               unquote(String.to_atom(support))

      parent = request(binding, operation)
      before = Jido.Signal.to_map(parent)
      assert {:ok, result} = Jido.Chat.execute(binding, parent)

      if unquote(support) == "unsupported" do
        assert result.type == "jido.chat.operation.failed" and
                 result.data["code"] == "unsupported"
      else
        assert result.type == "jido.chat.operation.completed"
      end

      assert calls() == unquote(Map.get(@calls, operation, []))
      assert {:ok, ^result} = Jido.Chat.execute(binding, parent)
      assert calls() == []
      assert Jido.Signal.to_map(parent) == before
      assert Context.get(result, "causationid") == parent.id
      assert Trace.get(result).trace_id == Trace.get(parent).trace_id
      portable(result)
      assert_participants(operation, result)
    end
  end

  defp assert_participants(:get_thread_participants, result) do
    assert result.data["result"]["complete"] == false
    assert result.data["result"]["scope"] in ["thread", "observed"]
    assert Enum.map(result.data["result"]["participants"], & &1["id"]) == ["1"]
  end

  defp assert_participants(_, _), do: :ok

  defp payload(action, comment \\ false) do
    payload = %{
      "action" => action,
      "repository" => %{"name" => "repo", "owner" => %{"login" => "owner"}},
      "issue" => %{
        "id" => 9,
        "number" => 42,
        "title" => "Title",
        "body" => "Body",
        "user" => %{"id" => 1, "login" => "user"}
      }
    }

    if comment,
      do:
        Map.put(payload, "comment", %{"id" => 123, "body" => "Comment", "user" => %{"id" => 2}}),
      else: payload
  end

  defp signed(kind, data, key \\ "delivery-1", secret \\ "private-token") do
    raw = Jason.encode!(data)
    signature = "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, secret, raw), case: :lower)

    WebhookRequest.new(%{
      payload: data,
      raw: raw,
      headers: %{
        "x-github-event" => kind,
        "x-github-delivery" => key,
        "x-hub-signature-256" => signature
      }
    })
  end

  defp event("MessageReceived"), do: {"issue_comment", payload("created", true)}
  defp event("MessageUpdated"), do: {"issue_comment", payload("edited", true)}
  defp event("ThreadStarted"), do: {"issues", payload("opened")}
  defp event("ThreadChanged"), do: {"issues", payload("reopened")}

  defp event(name) when name in ["ReactionAdded", "ReactionRemoved"] do
    action = if name == "ReactionAdded", do: "created", else: "deleted"

    {"reaction",
     payload(action, true)
     |> Map.put("reaction", %{"id" => 8, "content" => "+1", "user" => %{"id" => 2}})}
  end

  defp event(name), do: {name, %{"type" => name, "action" => "unknown"}}

  for {name, support} <- @row["event_support"] do
    test "#{name} matches frozen #{support} through a verified webhook", %{binding: binding} do
      {kind, payload} = event(unquote(name))
      assert {:ok, unit} = Jido.Chat.normalize_event(binding, signed(kind, payload))

      expected =
        if unquote(support) == "unsupported",
          do: "jido.chat.normalization.failed",
          else: Module.concat(Jido.Chat.Signal, unquote(name)).type()

      assert Enum.any?(unit.signals, &(&1.type == expected))
      assert {:ok, repeated} = Jido.Chat.normalize_event(binding, signed(kind, payload))

      assert Enum.map(unit.signals, & &1.data["item_id"]) ==
               Enum.map(repeated.signals, & &1.data["item_id"])

      Enum.each(unit.signals, &portable/1)
      assert calls() == []
    end
  end

  test "all lifecycle actions remain distinct and ordered", %{binding: binding} do
    fixtures = [
      {"issue_comment", payload("created", true)},
      {"issue_comment", payload("edited", true)},
      {"issues", payload("opened")},
      {"issues", payload("edited")},
      {"issues", payload("reopened")}
    ]

    requests =
      fixtures
      |> Enum.with_index()
      |> Enum.map(fn {{kind, data}, index} -> signed(kind, data, "#{index}") end)

    assert {:ok, unit} = Jido.Chat.normalize_event(binding, requests)

    assert Enum.map(unit.signals, & &1.type) == [
             "jido.chat.message.received",
             "jido.chat.message.updated",
             "jido.chat.thread.started",
             "jido.chat.message.received",
             "jido.chat.thread.changed",
             "jido.chat.message.updated",
             "jido.chat.thread.changed"
           ]

    assert Enum.map(
             Enum.filter(unit.signals, &(&1.type == "jido.chat.thread.changed")),
             & &1.data["change"]
           ) == ["updated", "reopened"]

    assert {:ok, %{signals: []}} = Jido.Chat.normalize_event(binding, signed("ping", %{}))
    assert {:ok, %{signals: []}} = Jido.Chat.normalize_event(binding, [])
  end

  test "verification and complete limits fail before acceptance; controls never expose private reasons",
       %{binding: binding} do
    bad = signed("issues", payload("opened"), "bad", "wrong")
    assert {:error, error} = Jido.Chat.normalize_event(binding, bad)
    assert Adapter.format_webhook_response({:error, error}, []).status == 400
    assert Adapter.format_webhook_response({:error, "private-token"}, []).status == 400

    refute inspect(Adapter.format_webhook_response({:error, "private-token"}, [])) =~
             "private-token"

    {:ok, unit} = Jido.Chat.normalize_event(binding, signed("issues", payload("opened")))
    assert Adapter.format_webhook_response({:ok, unit}, []).status == 200

    too_big =
      put_in(payload("created", true), ["comment", "body"], String.duplicate("x", 262_145))

    assert {:error, %{code: :signal_too_large}} =
             Jido.Chat.normalize_event(binding, signed("issue_comment", too_big))

    assert {:error, %{code: :too_many_signals}} =
             Jido.Chat.normalize_event(
               binding,
               Enum.map(1..129, &signed("issue_comment", payload("created", true), "#{&1}"))
             )

    assert {:error, %{code: :too_many_failures}} =
             Jido.Chat.normalize_event(binding, Enum.map(1..33, &signed("unknown", %{}, "#{&1}")))

    medium = put_in(payload("created", true), ["comment", "body"], String.duplicate("x", 100_000))

    assert {:error, %{code: :delivery_too_large}} =
             Jido.Chat.normalize_event(
               binding,
               Enum.map(1..11, &signed("issue_comment", medium, "#{&1}"))
             )

    assert calls() == []
  end

  test "failed provider work and cancelled streams cannot repeat callbacks", %{binding: binding} do
    Process.put(:provider_failure, true)
    parent = request(binding, :send_message)
    assert {:ok, result} = Jido.Chat.execute(binding, parent)
    assert result.type == "jido.chat.operation.failed"
    portable(result)
    assert calls() == [:create_issue_comment]
    assert {:ok, ^result} = Jido.Chat.execute(binding, parent)
    assert calls() == []
    Process.delete(:provider_failure)
    {:ok, ref} = Jido.Chat.put_resource(binding, "stream", ["a", "b"])
    :ok = Jido.Chat.cancel_resource(binding, ref)

    assert {:ok, %{type: "jido.chat.operation.failed"}} =
             Jido.Chat.execute(binding, request(binding, :stream, %{"resource_ref" => ref}))

    assert calls() == []
  end

  test "HTTP mapping uses the signed body and delivery identities are binding scoped", %{
    binding: binding
  } do
    signed = signed("issue_comment", payload("created", true))
    request = %{signed | payload: put_in(signed.payload, ["comment", "body"], "unsigned")}
    assert {:ok, first} = Jido.Chat.normalize_event(binding, request)
    assert hd(first.signals).data["text"] == "Comment"
    {:ok, other} = Jido.Chat.bind(Adapter, id: "other", webhook_secret: "private-token")
    assert {:ok, second} = Jido.Chat.normalize_event(other, request)
    refute first.id == second.id
  end
end
