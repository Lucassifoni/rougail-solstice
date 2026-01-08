defmodule RougailSolstice.InterferometryTest do
  use RougailSolstice.DataCase, async: true

  alias RougailSolstice.Interferometry
  alias RougailSolstice.Interferometry.Config

  @valid_attrs %{
    name: "Test Mirror",
    diameter: 203.0,
    roc: 1438.0,
    lambda: 518.0,
    conic: -1.0,
    obstruction: 0.0
  }

  describe "list_configs/0" do
    test "returns empty list when no configs exist" do
      assert Interferometry.list_configs() == []
    end

    test "returns all configs ordered by name" do
      {:ok, config_b} = Interferometry.create_config(Map.put(@valid_attrs, :name, "B Mirror"))
      {:ok, config_a} = Interferometry.create_config(Map.put(@valid_attrs, :name, "A Mirror"))

      assert Interferometry.list_configs() == [config_a, config_b]
    end
  end

  describe "get_config/1" do
    test "returns nil for non-existent id" do
      assert Interferometry.get_config(999) == nil
    end

    test "returns config by id" do
      {:ok, config} = Interferometry.create_config(@valid_attrs)
      assert Interferometry.get_config(config.id) == config
    end
  end

  describe "get_config!/1" do
    test "raises for non-existent id" do
      assert_raise Ecto.NoResultsError, fn ->
        Interferometry.get_config!(999)
      end
    end

    test "returns config by id" do
      {:ok, config} = Interferometry.create_config(@valid_attrs)
      assert Interferometry.get_config!(config.id) == config
    end
  end

  describe "get_default_config/0" do
    test "returns nil when no default exists" do
      {:ok, _config} = Interferometry.create_config(@valid_attrs)
      assert Interferometry.get_default_config() == nil
    end

    test "returns the default config" do
      {:ok, config} = Interferometry.create_config(Map.put(@valid_attrs, :is_default, true))
      assert Interferometry.get_default_config() == config
    end
  end

  describe "create_config/1" do
    test "creates config with valid attrs" do
      assert {:ok, %Config{} = config} = Interferometry.create_config(@valid_attrs)
      assert config.name == "Test Mirror"
      assert config.diameter == 203.0
      assert config.roc == 1438.0
      assert config.lambda == 518.0
      assert config.conic == -1.0
      assert config.obstruction == 0.0
      assert config.is_default == false
    end

    test "creates config with defaults" do
      minimal_attrs = %{name: "Minimal", diameter: 200.0, roc: 1000.0}
      assert {:ok, %Config{} = config} = Interferometry.create_config(minimal_attrs)
      assert config.lambda == 518.0
      assert config.conic == -1.0
      assert config.obstruction == 0.0
    end

    test "fails without required fields" do
      assert {:error, changeset} = Interferometry.create_config(%{})
      assert "can't be blank" in errors_on(changeset).name
      assert "can't be blank" in errors_on(changeset).diameter
      assert "can't be blank" in errors_on(changeset).roc
    end

    test "fails with invalid diameter" do
      assert {:error, changeset} =
               Interferometry.create_config(Map.put(@valid_attrs, :diameter, -10.0))

      assert "must be greater than 0" in errors_on(changeset).diameter
    end

    test "fails with invalid obstruction" do
      assert {:error, changeset} =
               Interferometry.create_config(Map.put(@valid_attrs, :obstruction, 1.5))

      assert "must be less than 1" in errors_on(changeset).obstruction
    end

    test "fails with duplicate name" do
      {:ok, _config} = Interferometry.create_config(@valid_attrs)
      assert {:error, changeset} = Interferometry.create_config(@valid_attrs)
      assert "has already been taken" in errors_on(changeset).name
    end
  end

  describe "update_config/2" do
    test "updates config with valid attrs" do
      {:ok, config} = Interferometry.create_config(@valid_attrs)
      assert {:ok, updated} = Interferometry.update_config(config, %{diameter: 250.0})
      assert updated.diameter == 250.0
    end

    test "fails with invalid attrs" do
      {:ok, config} = Interferometry.create_config(@valid_attrs)
      assert {:error, changeset} = Interferometry.update_config(config, %{diameter: -10.0})
      assert "must be greater than 0" in errors_on(changeset).diameter
    end
  end

  describe "delete_config/1" do
    test "deletes config" do
      {:ok, config} = Interferometry.create_config(@valid_attrs)
      assert {:ok, _} = Interferometry.delete_config(config)
      assert Interferometry.get_config(config.id) == nil
    end
  end

  describe "set_default/1" do
    test "sets config as default" do
      {:ok, config} = Interferometry.create_config(@valid_attrs)
      assert {:ok, updated} = Interferometry.set_default(config)
      assert updated.is_default == true
    end

    test "unsets previous default when setting new one" do
      {:ok, config1} = Interferometry.create_config(Map.put(@valid_attrs, :is_default, true))
      {:ok, config2} = Interferometry.create_config(Map.put(@valid_attrs, :name, "Other Mirror"))

      assert config1.is_default == true
      assert {:ok, _} = Interferometry.set_default(config2)

      config1_reloaded = Interferometry.get_config!(config1.id)
      config2_reloaded = Interferometry.get_config!(config2.id)

      assert config1_reloaded.is_default == false
      assert config2_reloaded.is_default == true
    end
  end
end
