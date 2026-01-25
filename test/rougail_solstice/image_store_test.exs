defmodule RougailSolstice.ImageStoreTest do
  use ExUnit.Case, async: true

  alias RougailSolstice.ImageStore

  setup do
    {:ok, store} = start_supervised({ImageStore, name: :test_image_store})
    %{store: store}
  end

  describe "extract_key/1" do
    test "extracts key from session URL" do
      assert {:ok, "preview_123"} = ImageStore.extract_key("/sessions/42/images/preview_123")
    end

    test "extracts key from simple images URL" do
      assert {:ok, "preview_123"} = ImageStore.extract_key("/images/preview_123")
    end

    test "returns error for invalid session URL without images part" do
      assert :error = ImageStore.extract_key("/sessions/42/other/thing")
    end

    test "returns error for unrelated path" do
      assert :error = ImageStore.extract_key("/api/v1/images")
    end

    test "returns error for empty string" do
      assert :error = ImageStore.extract_key("")
    end

    test "handles URL with nested session id and key" do
      assert {:ok, "full_shot_456"} = ImageStore.extract_key("/sessions/999/images/full_shot_456")
    end
  end

  describe "fetch_binary/2" do
    test "fetches binary from store using session URL", %{store: store} do
      ImageStore.put(store, "preview_1", "image_data", content_type: "image/jpeg")

      assert {:ok, "image_data"} = ImageStore.fetch_binary(store, "/sessions/42/images/preview_1")
    end

    test "fetches binary from store using simple images URL", %{store: store} do
      ImageStore.put(store, "preview_2", "image_data_2", content_type: "image/jpeg")

      assert {:ok, "image_data_2"} = ImageStore.fetch_binary(store, "/images/preview_2")
    end

    test "returns error for non-existent key", %{store: store} do
      assert {:error, :not_found} =
               ImageStore.fetch_binary(store, "/sessions/42/images/nonexistent")
    end

    test "returns error for invalid URL", %{store: store} do
      assert {:error, :invalid_url} = ImageStore.fetch_binary(store, "/api/v1/other")
    end

    test "returns error when binary is nil in entry", %{store: store} do
      Agent.update(store, fn state ->
        Map.put(state, "nil_binary", %{
          binary: nil,
          content_type: "image/jpeg",
          dimensions: nil,
          updated_at: System.monotonic_time()
        })
      end)

      assert {:error, :not_found} =
               ImageStore.fetch_binary(store, "/sessions/42/images/nil_binary")
    end
  end

  describe "put and get" do
    test "stores and retrieves binary with metadata", %{store: store} do
      ImageStore.put(store, "test_key", "binary_data",
        content_type: "image/png",
        dimensions: {640, 480}
      )

      entry = ImageStore.get(store, "test_key")
      assert entry.binary == "binary_data"
      assert entry.content_type == "image/png"
      assert entry.dimensions == {640, 480}
    end

    test "returns nil for non-existent key", %{store: store} do
      assert ImageStore.get(store, "nonexistent") == nil
    end
  end

  describe "session_url/2" do
    test "generates correct session URL" do
      assert ImageStore.session_url(42, "preview_123") == "/sessions/42/images/preview_123"
    end
  end
end
