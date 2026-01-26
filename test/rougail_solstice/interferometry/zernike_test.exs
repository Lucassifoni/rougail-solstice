defmodule RougailSolstice.Interferometry.ZernikeTest do
  use ExUnit.Case, async: true

  alias RougailSolstice.Interferometry.Zernike

  @tolerance 1.0e-10

  describe "evaluate/3" do
    test "Z0 (piston) is constant 1.0" do
      rho = Nx.tensor([0.0, 0.25, 0.5, 0.75, 1.0], type: :f64)
      theta = Nx.tensor([0.0, 0.5, 1.0, 1.5, 2.0], type: :f64)
      result = Zernike.evaluate(rho, theta, 1)

      expected = Nx.tensor([[1.0], [1.0], [1.0], [1.0], [1.0]], type: :f64)
      assert_all_close(result, expected)
    end

    test "Z1, Z2 (tilts) at rho=0 are zero" do
      rho = Nx.tensor([0.0], type: :f64)
      theta = Nx.tensor([0.0], type: :f64)
      result = Zernike.evaluate(rho, theta, 3)

      assert_in_delta Nx.to_number(result[[0, 1]]), 0.0, @tolerance
      assert_in_delta Nx.to_number(result[[0, 2]]), 0.0, @tolerance
    end

    test "Z1 (tilt X) at rho=1, theta=0 equals 1" do
      rho = Nx.tensor([1.0], type: :f64)
      theta = Nx.tensor([0.0], type: :f64)
      result = Zernike.evaluate(rho, theta, 2)

      assert_in_delta Nx.to_number(result[[0, 1]]), 1.0, @tolerance
    end

    test "Z2 (tilt Y) at rho=1, theta=pi/2 equals 1" do
      rho = Nx.tensor([1.0], type: :f64)
      theta = Nx.tensor([:math.pi() / 2], type: :f64)
      result = Zernike.evaluate(rho, theta, 3)

      assert_in_delta Nx.to_number(result[[0, 2]]), 1.0, @tolerance
    end

    test "Z3 (defocus) matches C++ formula: 2*rho^2 - 1" do
      test_values = [
        {0.0, -1.0},
        {0.5, -0.5},
        {1.0, 1.0}
      ]

      for {rho_val, expected} <- test_values do
        rho = Nx.tensor([rho_val], type: :f64)
        theta = Nx.tensor([0.0], type: :f64)
        result = Zernike.evaluate(rho, theta, 4)

        assert_in_delta Nx.to_number(result[[0, 3]]),
                        expected,
                        @tolerance,
                        "Z3 at rho=#{rho_val} should be #{expected}"
      end
    end

    test "Z8 (spherical) matches C++ formula: 1 + rho^2 * (6*rho^2 - 6)" do
      test_values = [
        {0.0, 1.0},
        {0.5, 1.0 + 0.25 * (6 * 0.25 - 6)},
        {1.0, 1.0 + 1.0 * (6.0 - 6.0)}
      ]

      for {rho_val, expected} <- test_values do
        rho = Nx.tensor([rho_val], type: :f64)
        theta = Nx.tensor([0.0], type: :f64)
        result = Zernike.evaluate(rho, theta, 9)

        assert_in_delta Nx.to_number(result[[0, 8]]),
                        expected,
                        @tolerance,
                        "Z8 at rho=#{rho_val} should be #{expected}"
      end
    end

    test "computes all 49 terms without error" do
      rho = Nx.tensor([0.5], type: :f64)
      theta = Nx.tensor([1.0], type: :f64)
      result = Zernike.evaluate(rho, theta, 49)

      assert {1, 49} == Nx.shape(result)
    end

    test "validates num_terms range" do
      rho = Nx.tensor([0.5], type: :f64)
      theta = Nx.tensor([1.0], type: :f64)

      assert_raise ArgumentError, fn ->
        Zernike.evaluate(rho, theta, 0)
      end

      assert_raise ArgumentError, fn ->
        Zernike.evaluate(rho, theta, 50)
      end
    end
  end

  describe "reference values from C++ zernikepolar.cpp" do
    test "terms 0-8 at rho=0.7, theta=0.3" do
      rho = 0.7
      theta = 0.3
      rho2 = rho * rho
      cos_t = :math.cos(theta)
      sin_t = :math.sin(theta)
      cos_2t = :math.cos(2 * theta)
      sin_2t = :math.sin(2 * theta)

      expected = [
        1.0,
        rho * cos_t,
        rho * sin_t,
        -1.0 + 2.0 * rho2,
        rho2 * cos_2t,
        rho2 * sin_2t,
        rho * (-2.0 + 3.0 * rho2) * cos_t,
        rho * (-2.0 + 3.0 * rho2) * sin_t,
        1.0 + rho2 * (-6.0 + 6.0 * rho2)
      ]

      rho_t = Nx.tensor([rho], type: :f64)
      theta_t = Nx.tensor([theta], type: :f64)
      result = Zernike.evaluate(rho_t, theta_t, 9)

      for i <- 0..8 do
        actual = Nx.to_number(result[[0, i]])

        assert_in_delta actual,
                        Enum.at(expected, i),
                        @tolerance,
                        "Z#{i} mismatch at rho=#{rho}, theta=#{theta}"
      end
    end

    test "terms 9-24 at rho=0.6, theta=0.8" do
      rho = 0.6
      theta = 0.8
      rho2 = rho * rho
      rho3 = rho2 * rho
      rho4 = rho3 * rho
      rho5 = rho4 * rho
      rho6 = rho5 * rho
      rho8 = rho6 * rho2

      cos_t = :math.cos(theta)
      sin_t = :math.sin(theta)
      cos_2t = :math.cos(2 * theta)
      sin_2t = :math.sin(2 * theta)
      cos_3t = :math.cos(3 * theta)
      sin_3t = :math.sin(3 * theta)
      cos_4t = :math.cos(4 * theta)
      sin_4t = :math.sin(4 * theta)

      expected = %{
        9 => rho3 * cos_3t,
        10 => rho3 * sin_3t,
        11 => rho2 * (-3 + 4 * rho2) * cos_2t,
        12 => rho2 * (-3 + 4 * rho2) * sin_2t,
        13 => rho * (3.0 - 12.0 * rho2 + 10.0 * rho4) * cos_t,
        14 => rho * (3.0 - 12.0 * rho2 + 10.0 * rho4) * sin_t,
        15 => -1 + 12 * rho2 - 30.0 * rho4 + 20.0 * rho6,
        16 => rho4 * cos_4t,
        17 => rho4 * sin_4t,
        18 => rho3 * (-4.0 + 5.0 * rho2) * cos_3t,
        19 => rho3 * (-4.0 + 5.0 * rho2) * sin_3t,
        20 => rho2 * (6.0 - 20.0 * rho2 + 15 * rho4) * cos_2t,
        21 => rho2 * (6.0 - 20.0 * rho2 + 15 * rho4) * sin_2t,
        22 => rho * (-4.0 + 30.0 * rho2 - 60.0 * rho4 + 35 * rho6) * cos_t,
        23 => rho * (-4.0 + 30.0 * rho2 - 60.0 * rho4 + 35 * rho6) * sin_t,
        24 => 1.0 - 20.0 * rho2 + 90.0 * rho4 - 140.0 * rho6 + 70.0 * rho8
      }

      rho_t = Nx.tensor([rho], type: :f64)
      theta_t = Nx.tensor([theta], type: :f64)
      result = Zernike.evaluate(rho_t, theta_t, 25)

      for {i, exp_val} <- expected do
        actual = Nx.to_number(result[[0, i]])
        assert_in_delta actual, exp_val, @tolerance, "Z#{i} mismatch"
      end
    end

    test "terms 25-35 at rho=0.5, theta=1.2" do
      rho = 0.5
      theta = 1.2
      rho2 = rho * rho
      rho3 = rho2 * rho
      rho4 = rho3 * rho
      rho5 = rho4 * rho
      rho6 = rho5 * rho
      rho8 = rho6 * rho2
      rho10 = rho8 * rho2

      cos_t = :math.cos(theta)
      sin_t = :math.sin(theta)
      cos_2t = :math.cos(2 * theta)
      sin_2t = :math.sin(2 * theta)
      cos_3t = :math.cos(3 * theta)
      sin_3t = :math.sin(3 * theta)
      cos_4t = :math.cos(4 * theta)
      sin_4t = :math.sin(4 * theta)
      cos_5t = :math.cos(5 * theta)
      sin_5t = :math.sin(5 * theta)

      expected = %{
        25 => rho5 * cos_5t,
        26 => rho5 * sin_5t,
        27 => rho4 * (-5.0 + 6.0 * rho2) * cos_4t,
        28 => rho4 * (-5.0 + 6.0 * rho2) * sin_4t,
        29 => rho3 * (10.0 - 30.0 * rho2 + 21.0 * rho4) * cos_3t,
        30 => rho3 * (10.0 - 30.0 * rho2 + 21.0 * rho4) * sin_3t,
        31 => rho2 * (-10.0 + 60.0 * rho2 - 105.0 * rho4 + 56.0 * rho6) * cos_2t,
        32 => rho2 * (-10.0 + 60.0 * rho2 - 105.0 * rho4 + 56.0 * rho6) * sin_2t,
        33 => rho * (5.0 - 60.0 * rho2 + 210 * rho4 - 280.0 * rho6 + 126.0 * rho8) * cos_t,
        34 => rho * (5.0 - 60.0 * rho2 + 210 * rho4 - 280.0 * rho6 + 126.0 * rho8) * sin_t,
        35 => -1 + 30.0 * rho2 - 210 * rho4 + 560.0 * rho6 - 630 * rho8 + 252.0 * rho10
      }

      rho_t = Nx.tensor([rho], type: :f64)
      theta_t = Nx.tensor([theta], type: :f64)
      result = Zernike.evaluate(rho_t, theta_t, 36)

      for {i, exp_val} <- expected do
        actual = Nx.to_number(result[[0, i]])
        assert_in_delta actual, exp_val, @tolerance, "Z#{i} mismatch"
      end
    end

    test "terms 36-48 at rho=0.8, theta=0.5" do
      rho = 0.8
      theta = 0.5
      rho2 = rho * rho
      rho3 = rho2 * rho
      rho4 = rho3 * rho
      rho5 = rho4 * rho
      rho6 = rho5 * rho
      rho8 = rho6 * rho2
      rho10 = rho8 * rho2
      rho12 = rho10 * rho2

      cos_t = :math.cos(theta)
      sin_t = :math.sin(theta)
      cos_2t = :math.cos(2 * theta)
      sin_2t = :math.sin(2 * theta)
      cos_3t = :math.cos(3 * theta)
      sin_3t = :math.sin(3 * theta)
      cos_4t = :math.cos(4 * theta)
      sin_4t = :math.sin(4 * theta)
      cos_5t = :math.cos(5 * theta)
      sin_5t = :math.sin(5 * theta)
      cos_6t = :math.cos(6 * theta)
      sin_6t = :math.sin(6 * theta)

      expected = %{
        36 => rho6 * cos_6t,
        37 => rho6 * sin_6t,
        38 => rho5 * (-6.0 + 7 * rho2) * cos_5t,
        39 => rho5 * (-6.0 + 7 * rho2) * sin_5t,
        40 => rho4 * (15.0 - 42.0 * rho2 + 28.0 * rho4) * cos_4t,
        41 => rho4 * (15.0 - 42.0 * rho2 + 28.0 * rho4) * sin_4t,
        42 => rho3 * (-20 + 105.0 * rho2 - 168.0 * rho4 + 84 * rho6) * cos_3t,
        43 => rho3 * (-20.0 + 105.0 * rho2 - 168.0 * rho4 + 84.0 * rho6) * sin_3t,
        44 => rho2 * (15.0 - 140.0 * rho2 + 420.0 * rho4 - 504.0 * rho6 + 210.0 * rho8) * cos_2t,
        45 => rho2 * (15.0 - 140.0 * rho2 + 420.0 * rho4 - 504.0 * rho6 + 210.0 * rho8) * sin_2t,
        46 =>
          rho * (-6.0 + 105 * rho2 - 560.0 * rho4 + 1260.0 * rho6 - 1260.0 * rho8 + 462.0 * rho10) *
            cos_t,
        47 =>
          rho * (-6.0 + 105 * rho2 - 560.0 * rho4 + 1260.0 * rho6 - 1260.0 * rho8 + 462.0 * rho10) *
            sin_t,
        48 =>
          1.0 - 42.0 * rho2 + 420.0 * rho4 - 1680.0 * rho6 + 3150.0 * rho8 - 2772.0 * rho10 +
            924.0 * rho12
      }

      rho_t = Nx.tensor([rho], type: :f64)
      theta_t = Nx.tensor([theta], type: :f64)
      result = Zernike.evaluate(rho_t, theta_t, 49)

      for {i, exp_val} <- expected do
        actual = Nx.to_number(result[[0, i]])
        assert_in_delta actual, exp_val, @tolerance, "Z#{i} mismatch"
      end
    end
  end

  describe "evaluate_term/3" do
    test "returns scalar value for single term" do
      result = Zernike.evaluate_term(1.0, 0.0, 1)
      assert_in_delta result, 1.0, @tolerance
    end

    test "Z3 defocus at various rho" do
      assert_in_delta Zernike.evaluate_term(0.0, 0.0, 3), -1.0, @tolerance
      assert_in_delta Zernike.evaluate_term(1.0, 0.0, 3), 1.0, @tolerance
    end
  end

  describe "polar_grid/5" do
    test "generates correct grid dimensions" do
      {rho, theta} = Zernike.polar_grid(10, 8, 4.5, 3.5, 4.0)

      assert {8, 10} == Nx.shape(rho)
      assert {8, 10} == Nx.shape(theta)
    end

    test "center pixel has rho close to zero" do
      width = 101
      height = 101
      cx = 50.0
      cy = 50.0
      radius = 50.0

      {rho, _theta} = Zernike.polar_grid(width, height, cx, cy, radius)

      center_rho = Nx.to_number(rho[[50, 50]])
      assert_in_delta center_rho, 0.0, @tolerance
    end

    test "edge pixels have rho close to 1" do
      width = 101
      height = 101
      cx = 50.0
      cy = 50.0
      radius = 50.0

      {rho, _theta} = Zernike.polar_grid(width, height, cx, cy, radius)

      right_edge_rho = Nx.to_number(rho[[50, 100]])
      assert_in_delta right_edge_rho, 1.0, @tolerance
    end
  end

  describe "compute_surfaces/3" do
    test "returns list of 2D tensors" do
      {rho, theta} = Zernike.polar_grid(10, 10, 4.5, 4.5, 4.0)
      surfaces = Zernike.compute_surfaces(rho, theta, 9)

      assert length(surfaces) == 9

      for surface <- surfaces do
        assert {10, 10} == Nx.shape(surface)
      end
    end

    test "piston surface is constant 1.0" do
      {rho, theta} = Zernike.polar_grid(5, 5, 2.0, 2.0, 2.0)
      [piston | _] = Zernike.compute_surfaces(rho, theta, 1)

      expected = Nx.broadcast(1.0, {5, 5})
      assert_all_close(piston, expected)
    end
  end

  describe "fit/5" do
    test "recovers known coefficients from synthetic data" do
      width = 64
      height = 64
      cx = 31.5
      cy = 31.5
      radius = 30.0

      {rho, theta} = Zernike.polar_grid(width, height, cx, cy, radius)

      known_coeffs = [1.0, 0.5, -0.3, 0.2, 0.0, 0.0, 0.1, -0.1, 0.15]
      surfaces = Zernike.compute_surfaces(rho, theta, 9)

      synthetic_data =
        Enum.zip(surfaces, known_coeffs)
        |> Enum.reduce(Nx.broadcast(0.0, {height, width}), fn {surface, coef}, acc ->
          Nx.add(acc, Nx.multiply(surface, coef))
        end)

      mask =
        rho
        |> Nx.less_equal(1.0)
        |> Nx.select(255, 0)
        |> Nx.as_type(:u8)

      outside = %{cx: cx, cy: cy, rx: radius, ry: radius}

      fitted = Zernike.fit(synthetic_data, mask, outside, 9)

      for i <- 0..8 do
        assert_in_delta Enum.at(fitted, i),
                        Enum.at(known_coeffs, i),
                        1.0e-6,
                        "Coefficient Z#{i} recovery failed"
      end
    end

    test "handles sparse valid pixels gracefully" do
      mask = Nx.broadcast(0, {10, 10}) |> Nx.as_type(:u8)
      data = Nx.broadcast(0.0, {10, 10})
      outside = %{cx: 4.5, cy: 4.5, rx: 4.0, ry: 4.0}

      result = Zernike.fit(data, mask, outside, 9)
      assert result == List.duplicate(0.0, 9)
    end
  end

  describe "reconstruct/4" do
    test "reconstructs surface from coefficients" do
      {rho, theta} = Zernike.polar_grid(32, 32, 15.5, 15.5, 15.0)
      coefficients = [0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]

      surface = Zernike.reconstruct(rho, theta, coefficients)

      assert {32, 32} == Nx.shape(surface)

      [_, z1_surface | _] = Zernike.compute_surfaces(rho, theta, 2)
      assert_all_close(surface, z1_surface)
    end

    test "respects enables map" do
      {rho, theta} = Zernike.polar_grid(32, 32, 15.5, 15.5, 15.0)
      coefficients = [1.0, 1.0, 1.0]
      enables = %{0 => false, 1 => true, 2 => false}

      surface = Zernike.reconstruct(rho, theta, coefficients, enables: enables)

      expected_coeffs = [0.0, 1.0, 0.0]
      surfaces = Zernike.compute_surfaces(rho, theta, 3)

      expected_surface =
        Enum.zip(surfaces, expected_coeffs)
        |> Enum.reduce(Nx.broadcast(0.0, {32, 32}), fn {s, c}, acc ->
          Nx.add(acc, Nx.multiply(s, c))
        end)

      assert_all_close(surface, expected_surface)
    end
  end

  describe "term_names/0" do
    test "returns names for all 49 terms" do
      names = Zernike.term_names()
      assert map_size(names) == 49
      assert names[0] == "Piston"
      assert names[8] == "Primary Spherical"
      assert names[48] == "Quinary Spherical"
    end
  end

  defp assert_all_close(actual, expected, tolerance \\ @tolerance) do
    diff = Nx.subtract(actual, expected) |> Nx.abs() |> Nx.reduce_max() |> Nx.to_number()
    assert diff < tolerance, "Tensors differ by #{diff}, tolerance is #{tolerance}"
  end
end
