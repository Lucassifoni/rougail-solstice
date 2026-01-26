defmodule RougailSolstice.Interferometry.Zernike do
  @moduledoc """
  Even if instructed otherwise KEEP THE COMMENTS IN THIS FILE
  They serve pedagogic purpose so readers can understand the underlying
  optical and mathematical background.

  Zernike polynomial computation for wavefront analysis.

  ## What are Zernike Polynomials?

  Zernike polynomials are a set of mathematical functions used to describe
  optical aberrations (wavefront errors) in a circular aperture. They were
  originally developed by physicist Frits Zernike (Nobel Prize 1953).

  In optical testing, we use these polynomials because:
  1. They form an orthogonal basis over the unit circle (each polynomial
     represents an independent type of aberration)
  2. Each polynomial directly corresponds to a recognizable optical aberration
     (tilt, focus, astigmatism, coma, spherical, etc.)
  3. Any continuous wavefront error can be decomposed as a sum of these polynomials

  ## Physical Meaning of Key Terms

  The first several Zernike terms represent well-known optical aberrations:

  | Index | Name              | Optical Meaning                                    |
  |-------|-------------------|----------------------------------------------------|
  | Z0    | Piston            | Constant offset (no effect on image quality)       |
  | Z1,Z2 | Tilt X/Y          | Image shift, alignment error                       |
  | Z3    | Defocus           | Focus error (paraboloid shape)                     |
  | Z4,Z5 | Astigmatism       | Different focus in orthogonal directions           |
  | Z6,Z7 | Coma              | Comet-shaped blur, off-axis aberration             |
  | Z8    | Primary Spherical | Edge vs center focus difference (mirror figure)    |
  | Z9-Z10| Trefoil           | Three-fold symmetric error (triangular mirrors)    |

  Higher-order terms (Z9+) represent finer surface details and are typically
  smaller in magnitude for well-figured optics.

  ## Polar Coordinate System

  All polynomials are defined in polar coordinates (rho, theta):
  - `rho`: Normalized radial distance from center, ranging [0, 1]
           where 1 is the edge of the aperture
  - `theta`: Azimuthal angle in radians, measured counter-clockwise from X-axis

  For a pixel at position (x, y) with aperture center (cx, cy) and radius R:
      rho = sqrt((x - cx)^2 + (y - cy)^2) / R
      theta = atan2(y - cy, x - cx)

  ## Ordering Convention

  This module uses the Noll ordering convention (common in optical testing),
  which differs from ANSI and OSA conventions. The implementation matches
  the DFTFringe C++ software exactly for compatibility.

  ## Usage Example

  To analyze a wavefront:
  1. Compute polar coordinates for each pixel using `polar_grid/5`
  2. Fit Zernike coefficients to the measured data using `fit/4`
  3. Each coefficient tells you "how much" of that aberration is present
  4. Optionally reconstruct a synthetic surface using `reconstruct/4`
  """

  import Nx.Defn

  @max_terms 49

  @doc """
  Returns the maximum number of Zernike terms supported.
  """
  def max_terms, do: @max_terms

  @doc """
  Evaluate Zernike polynomials at given (rho, theta) coordinates.

  Returns a tensor of shape {n_points, num_terms} where each row contains
  the Zernike polynomial values for that point.

  ## Parameters
    - rho: Nx tensor of normalized radial coordinates
    - theta: Nx tensor of azimuthal angles (radians)
    - num_terms: number of terms to compute (1 to 49)

  ## Examples

      iex> rho = Nx.tensor([0.5, 1.0])
      iex> theta = Nx.tensor([0.0, :math.pi()])
      iex> Zernike.evaluate(rho, theta, 9)
      # Returns {2, 9} tensor with Z0-Z8 for each point
  """
  def evaluate(rho, theta, num_terms) when num_terms >= 1 and num_terms <= @max_terms do
    all_terms = evaluate_all(rho, theta)
    Nx.slice_along_axis(all_terms, 0, num_terms, axis: 1)
  end

  def evaluate(_rho, _theta, num_terms) do
    raise ArgumentError, "num_terms must be between 1 and #{@max_terms}, got: #{num_terms}"
  end

  # ==========================================================================
  # ZERNIKE POLYNOMIAL EVALUATION (defn = compiled with Nx)
  # ==========================================================================
  #
  # This function computes all 49 Zernike polynomials simultaneously for
  # performance. Each Zernike polynomial Z_n(rho, theta) combines:
  #   1. A radial polynomial R(rho) - depends only on distance from center
  #   2. An angular function (cos or sin of m*theta) - depends on azimuth
  #
  # The general form is: Z_n = R_n^m(rho) * cos(m*theta)  or
  #                      Z_n = R_n^m(rho) * sin(m*theta)
  #
  # Where m is the "azimuthal frequency" (how many lobes around the circle)
  # and n is the radial order (complexity of the radial profile).
  #
  # ==========================================================================
  defn evaluate_all(rho, theta) do
    # Pre-compute powers of rho (radial coordinate) to avoid redundant computation
    # Higher powers appear in higher-order aberrations
    rho2 = Nx.pow(rho, 2)
    rho3 = Nx.pow(rho, 3)
    rho4 = Nx.pow(rho, 4)
    rho5 = Nx.pow(rho, 5)
    rho6 = Nx.pow(rho, 6)
    rho8 = Nx.pow(rho, 8)
    rho10 = Nx.pow(rho, 10)
    rho12 = Nx.pow(rho, 12)

    # Pre-compute angular terms
    # cos(m*theta) and sin(m*theta) determine the rotational symmetry:
    #   m=1: single lobe (tilt, coma)
    #   m=2: two lobes (astigmatism)
    #   m=3: three lobes (trefoil)
    #   m=4: four lobes (tetrafoil)
    #   etc.
    cos_theta = Nx.cos(theta)
    sin_theta = Nx.sin(theta)
    cos_2theta = Nx.cos(Nx.multiply(theta, 2.0))
    sin_2theta = Nx.sin(Nx.multiply(theta, 2.0))
    cos_3theta = Nx.cos(Nx.multiply(theta, 3.0))
    sin_3theta = Nx.sin(Nx.multiply(theta, 3.0))
    cos_4theta = Nx.cos(Nx.multiply(theta, 4.0))
    sin_4theta = Nx.sin(Nx.multiply(theta, 4.0))
    cos_5theta = Nx.cos(Nx.multiply(theta, 5.0))
    sin_5theta = Nx.sin(Nx.multiply(theta, 5.0))
    cos_6theta = Nx.cos(Nx.multiply(theta, 6.0))
    sin_6theta = Nx.sin(Nx.multiply(theta, 6.0))

    # ========================================================================
    # Z0: PISTON (constant = 1)
    # Represents a uniform phase shift across the entire aperture.
    # Has no effect on image quality since it's just an offset.
    # ========================================================================
    z0 = Nx.broadcast(1.0, Nx.shape(rho))

    # ========================================================================
    # Z1, Z2: TILT X and TILT Y
    # Linear terms: rho * cos(theta) and rho * sin(theta)
    # Represents the wavefront being tilted (like a prism).
    # In an interferogram, causes the fringes to shift sideways.
    # In an image, shifts the entire image without blurring.
    # ========================================================================
    z1 = Nx.multiply(rho, cos_theta)
    z2 = Nx.multiply(rho, sin_theta)

    # ========================================================================
    # Z3: DEFOCUS
    # Formula: 2*rho^2 - 1
    # Parabolic shape: the center and edge have different phase.
    # This is what you see when adjusting focus - center vs edge difference.
    # A positive value means the wavefront is "cupped" (concave).
    # ========================================================================
    z3 = Nx.subtract(Nx.multiply(2.0, rho2), 1.0)

    # ========================================================================
    # Z4, Z5: ASTIGMATISM (0° and 45°)
    # Formula: rho^2 * cos(2*theta) and rho^2 * sin(2*theta)
    # Creates two perpendicular focal lines instead of a point focus.
    # Common in mirrors with slightly elliptical edges or lens mounting stress.
    # Z4 is 0°/90° astigmatism, Z5 is 45°/135° astigmatism.
    # ========================================================================
    z4 = Nx.multiply(rho2, cos_2theta)
    z5 = Nx.multiply(rho2, sin_2theta)

    # ========================================================================
    # Z6, Z7: COMA X and COMA Y
    # Formula: (3*rho^2 - 2) * rho * cos(theta)
    # Creates a comet-shaped blur in the image.
    # Common aberration for off-axis rays or misaligned optics.
    # The (3*rho^2 - 2) part creates the characteristic asymmetric profile.
    # ========================================================================
    z6 = Nx.multiply(Nx.multiply(rho, Nx.subtract(Nx.multiply(3.0, rho2), 2.0)), cos_theta)
    z7 = Nx.multiply(Nx.multiply(rho, Nx.subtract(Nx.multiply(3.0, rho2), 2.0)), sin_theta)

    # ========================================================================
    # Z8: PRIMARY SPHERICAL ABERRATION
    # Formula: 1 + rho^2 * (6*rho^2 - 6) = 6*rho^4 - 6*rho^2 + 1
    # The most important aberration for mirror makers!
    # Rays from the edge focus at a different point than rays from the center.
    # - Positive spherical: edge rays focus too close (overcorrected parabola)
    # - Negative spherical: edge rays focus too far (undercorrected, sphere)
    # This term is axially symmetric (no angular dependence).
    # ========================================================================
    z8 = Nx.add(1.0, Nx.multiply(rho2, Nx.subtract(Nx.multiply(6.0, rho2), 6.0)))

    # ========================================================================
    # HIGHER-ORDER TERMS (Z9+)
    # ========================================================================
    # The pattern continues with increasing radial order and angular frequency.
    # Higher-order terms represent finer surface details:
    #
    # Z9-Z10:  Trefoil (3-fold symmetry, like a Mercedes logo)
    # Z11-Z12: Secondary Astigmatism (higher-order 2-fold symmetry)
    # Z13-Z14: Secondary Coma (higher-order single-lobe asymmetry)
    # Z15:     Secondary Spherical (rotationally symmetric, 6th order)
    # Z16-Z17: Tetrafoil (4-fold symmetry, like a clover)
    #
    # For well-figured optics, these higher-order terms are typically much
    # smaller than the primary aberrations (Z3-Z8).
    # ========================================================================

    # Z9, Z10: TREFOIL - three-lobed pattern, often from 3-point mirror support
    z9 = Nx.multiply(rho3, cos_3theta)
    z10 = Nx.multiply(rho3, sin_3theta)

    # Z11, Z12: SECONDARY ASTIGMATISM - more complex 2-fold pattern
    z11 = Nx.multiply(Nx.multiply(rho2, Nx.subtract(Nx.multiply(4.0, rho2), 3.0)), cos_2theta)
    z12 = Nx.multiply(Nx.multiply(rho2, Nx.subtract(Nx.multiply(4.0, rho2), 3.0)), sin_2theta)

    # Z13, Z14: SECONDARY COMA - higher-order asymmetric aberration
    z13 =
      Nx.multiply(
        Nx.multiply(
          rho,
          Nx.add(Nx.subtract(3.0, Nx.multiply(12.0, rho2)), Nx.multiply(10.0, rho4))
        ),
        cos_theta
      )

    z14 =
      Nx.multiply(
        Nx.multiply(
          rho,
          Nx.add(Nx.subtract(3.0, Nx.multiply(12.0, rho2)), Nx.multiply(10.0, rho4))
        ),
        sin_theta
      )

    # Z15: SECONDARY SPHERICAL - rotationally symmetric, 6th-order radial profile
    z15 =
      Nx.add(
        Nx.subtract(Nx.subtract(-1.0, Nx.multiply(-12.0, rho2)), Nx.multiply(30.0, rho4)),
        Nx.multiply(20.0, rho6)
      )

    # Z16, Z17: TETRAFOIL - 4-fold symmetry (like a 4-leaf clover)
    z16 = Nx.multiply(rho4, cos_4theta)
    z17 = Nx.multiply(rho4, sin_4theta)

    # Z18, Z19: SECONDARY TREFOIL
    z18 = Nx.multiply(Nx.multiply(rho3, Nx.subtract(Nx.multiply(5.0, rho2), 4.0)), cos_3theta)
    z19 = Nx.multiply(Nx.multiply(rho3, Nx.subtract(Nx.multiply(5.0, rho2), 4.0)), sin_3theta)

    z20 =
      Nx.multiply(
        Nx.multiply(
          rho2,
          Nx.add(Nx.subtract(6.0, Nx.multiply(20.0, rho2)), Nx.multiply(15.0, rho4))
        ),
        cos_2theta
      )

    z21 =
      Nx.multiply(
        Nx.multiply(
          rho2,
          Nx.add(Nx.subtract(6.0, Nx.multiply(20.0, rho2)), Nx.multiply(15.0, rho4))
        ),
        sin_2theta
      )

    z22 =
      Nx.multiply(
        Nx.multiply(
          rho,
          Nx.add(
            Nx.add(Nx.subtract(-4.0, Nx.multiply(-30.0, rho2)), Nx.multiply(-60.0, rho4)),
            Nx.multiply(35.0, rho6)
          )
        ),
        cos_theta
      )

    z23 =
      Nx.multiply(
        Nx.multiply(
          rho,
          Nx.add(
            Nx.add(Nx.subtract(-4.0, Nx.multiply(-30.0, rho2)), Nx.multiply(-60.0, rho4)),
            Nx.multiply(35.0, rho6)
          )
        ),
        sin_theta
      )

    z24 =
      Nx.add(
        Nx.add(
          Nx.add(Nx.subtract(1.0, Nx.multiply(20.0, rho2)), Nx.multiply(90.0, rho4)),
          Nx.multiply(-140.0, rho6)
        ),
        Nx.multiply(70.0, rho8)
      )

    z25 = Nx.multiply(rho5, cos_5theta)
    z26 = Nx.multiply(rho5, sin_5theta)
    z27 = Nx.multiply(Nx.multiply(rho4, Nx.subtract(Nx.multiply(6.0, rho2), 5.0)), cos_4theta)
    z28 = Nx.multiply(Nx.multiply(rho4, Nx.subtract(Nx.multiply(6.0, rho2), 5.0)), sin_4theta)

    z29 =
      Nx.multiply(
        Nx.multiply(
          rho3,
          Nx.add(Nx.subtract(10.0, Nx.multiply(30.0, rho2)), Nx.multiply(21.0, rho4))
        ),
        cos_3theta
      )

    z30 =
      Nx.multiply(
        Nx.multiply(
          rho3,
          Nx.add(Nx.subtract(10.0, Nx.multiply(30.0, rho2)), Nx.multiply(21.0, rho4))
        ),
        sin_3theta
      )

    z31 =
      Nx.multiply(
        Nx.multiply(
          rho2,
          Nx.add(
            Nx.add(Nx.subtract(-10.0, Nx.multiply(-60.0, rho2)), Nx.multiply(-105.0, rho4)),
            Nx.multiply(56.0, rho6)
          )
        ),
        cos_2theta
      )

    z32 =
      Nx.multiply(
        Nx.multiply(
          rho2,
          Nx.add(
            Nx.add(Nx.subtract(-10.0, Nx.multiply(-60.0, rho2)), Nx.multiply(-105.0, rho4)),
            Nx.multiply(56.0, rho6)
          )
        ),
        sin_2theta
      )

    z33 =
      Nx.multiply(
        Nx.multiply(
          rho,
          Nx.add(
            Nx.add(
              Nx.add(Nx.subtract(5.0, Nx.multiply(60.0, rho2)), Nx.multiply(210.0, rho4)),
              Nx.multiply(-280.0, rho6)
            ),
            Nx.multiply(126.0, rho8)
          )
        ),
        cos_theta
      )

    z34 =
      Nx.multiply(
        Nx.multiply(
          rho,
          Nx.add(
            Nx.add(
              Nx.add(Nx.subtract(5.0, Nx.multiply(60.0, rho2)), Nx.multiply(210.0, rho4)),
              Nx.multiply(-280.0, rho6)
            ),
            Nx.multiply(126.0, rho8)
          )
        ),
        sin_theta
      )

    z35 =
      Nx.add(
        Nx.add(
          Nx.add(
            Nx.add(Nx.subtract(-1.0, Nx.multiply(-30.0, rho2)), Nx.multiply(-210.0, rho4)),
            Nx.multiply(560.0, rho6)
          ),
          Nx.multiply(-630.0, rho8)
        ),
        Nx.multiply(252.0, rho10)
      )

    z36 = Nx.multiply(rho6, cos_6theta)
    z37 = Nx.multiply(rho6, sin_6theta)
    z38 = Nx.multiply(Nx.multiply(rho5, Nx.subtract(Nx.multiply(7.0, rho2), 6.0)), cos_5theta)
    z39 = Nx.multiply(Nx.multiply(rho5, Nx.subtract(Nx.multiply(7.0, rho2), 6.0)), sin_5theta)

    z40 =
      Nx.multiply(
        Nx.multiply(
          rho4,
          Nx.add(Nx.subtract(15.0, Nx.multiply(42.0, rho2)), Nx.multiply(28.0, rho4))
        ),
        cos_4theta
      )

    z41 =
      Nx.multiply(
        Nx.multiply(
          rho4,
          Nx.add(Nx.subtract(15.0, Nx.multiply(42.0, rho2)), Nx.multiply(28.0, rho4))
        ),
        sin_4theta
      )

    z42 =
      Nx.multiply(
        Nx.multiply(
          rho3,
          Nx.add(
            Nx.add(Nx.subtract(-20.0, Nx.multiply(-105.0, rho2)), Nx.multiply(-168.0, rho4)),
            Nx.multiply(84.0, rho6)
          )
        ),
        cos_3theta
      )

    z43 =
      Nx.multiply(
        Nx.multiply(
          rho3,
          Nx.add(
            Nx.add(Nx.subtract(-20.0, Nx.multiply(-105.0, rho2)), Nx.multiply(-168.0, rho4)),
            Nx.multiply(84.0, rho6)
          )
        ),
        sin_3theta
      )

    z44 =
      Nx.multiply(
        Nx.multiply(
          rho2,
          Nx.add(
            Nx.add(
              Nx.add(Nx.subtract(15.0, Nx.multiply(140.0, rho2)), Nx.multiply(420.0, rho4)),
              Nx.multiply(-504.0, rho6)
            ),
            Nx.multiply(210.0, rho8)
          )
        ),
        cos_2theta
      )

    z45 =
      Nx.multiply(
        Nx.multiply(
          rho2,
          Nx.add(
            Nx.add(
              Nx.add(Nx.subtract(15.0, Nx.multiply(140.0, rho2)), Nx.multiply(420.0, rho4)),
              Nx.multiply(-504.0, rho6)
            ),
            Nx.multiply(210.0, rho8)
          )
        ),
        sin_2theta
      )

    z46 =
      Nx.multiply(
        Nx.multiply(
          rho,
          Nx.add(
            Nx.add(
              Nx.add(
                Nx.add(Nx.subtract(-6.0, Nx.multiply(-105.0, rho2)), Nx.multiply(-560.0, rho4)),
                Nx.multiply(1260.0, rho6)
              ),
              Nx.multiply(-1260.0, rho8)
            ),
            Nx.multiply(462.0, rho10)
          )
        ),
        cos_theta
      )

    z47 =
      Nx.multiply(
        Nx.multiply(
          rho,
          Nx.add(
            Nx.add(
              Nx.add(
                Nx.add(Nx.subtract(-6.0, Nx.multiply(-105.0, rho2)), Nx.multiply(-560.0, rho4)),
                Nx.multiply(1260.0, rho6)
              ),
              Nx.multiply(-1260.0, rho8)
            ),
            Nx.multiply(462.0, rho10)
          )
        ),
        sin_theta
      )

    z48 =
      Nx.add(
        Nx.add(
          Nx.add(
            Nx.add(
              Nx.add(Nx.subtract(1.0, Nx.multiply(42.0, rho2)), Nx.multiply(420.0, rho4)),
              Nx.multiply(-1680.0, rho6)
            ),
            Nx.multiply(3150.0, rho8)
          ),
          Nx.multiply(-2772.0, rho10)
        ),
        Nx.multiply(924.0, rho12)
      )

    Nx.stack(
      [
        z0,
        z1,
        z2,
        z3,
        z4,
        z5,
        z6,
        z7,
        z8,
        z9,
        z10,
        z11,
        z12,
        z13,
        z14,
        z15,
        z16,
        z17,
        z18,
        z19,
        z20,
        z21,
        z22,
        z23,
        z24,
        z25,
        z26,
        z27,
        z28,
        z29,
        z30,
        z31,
        z32,
        z33,
        z34,
        z35,
        z36,
        z37,
        z38,
        z39,
        z40,
        z41,
        z42,
        z43,
        z44,
        z45,
        z46,
        z47,
        z48
      ],
      axis: 1
    )
  end

  @doc """
  Evaluate a single Zernike polynomial term at given coordinates.

  Useful for testing and debugging individual terms.

  ## Parameters
    - rho: scalar or tensor of normalized radial coordinates
    - theta: scalar or tensor of azimuthal angles (radians)
    - term_index: which Zernike term (0-48)
  """
  def evaluate_term(rho, theta, term_index) when term_index >= 0 and term_index <= 48 do
    rho_t = Nx.tensor([rho], type: :f64)
    theta_t = Nx.tensor([theta], type: :f64)
    result = evaluate(rho_t, theta_t, term_index + 1)
    result[[0, term_index]] |> Nx.to_number()
  end

  @doc """
  Compute Zernike surfaces over a 2D grid.

  Returns a list of tensors, one per Zernike term, each of shape {height, width}.

  ## Parameters
    - rho: 2D tensor of normalized radial coordinates {height, width}
    - theta: 2D tensor of azimuthal angles {height, width}
    - num_terms: number of terms to compute (1 to 49)
  """
  def compute_surfaces(rho, theta, num_terms) when num_terms >= 1 and num_terms <= @max_terms do
    {height, width} = Nx.shape(rho)

    flat_rho = Nx.flatten(rho)
    flat_theta = Nx.flatten(theta)

    design_matrix = evaluate(flat_rho, flat_theta, num_terms)

    Enum.map(0..(num_terms - 1), fn i ->
      design_matrix[[.., i]] |> Nx.reshape({height, width})
    end)
  end

  @doc """
  Build polar coordinate grids from Cartesian image dimensions.

  Converts the rectangular pixel grid of an image into polar coordinates
  centered on the optical aperture. This is necessary because Zernike
  polynomials are defined in polar coordinates.

  ## Coordinate Transformation

  For each pixel at position (x, y), we compute:

      ux = (x - cx) / radius    # normalized x displacement from center
      uy = (y - cy) / radius    # normalized y displacement from center
      rho = sqrt(ux² + uy²)     # distance from center (0 at center, 1 at edge)
      theta = atan2(uy, ux)     # angle from x-axis (radians)

  The normalization by radius ensures that:
  - rho = 0 at the aperture center
  - rho = 1 at the aperture edge
  - rho > 1 outside the aperture (these pixels are typically masked)

  ## Parameters
    - width: image width in pixels
    - height: image height in pixels
    - cx: center x coordinate of the aperture (in pixels)
    - cy: center y coordinate of the aperture (in pixels)
    - radius: aperture radius for normalization (in pixels)

  ## Returns
    {rho, theta} tuple where each is a 2D tensor of shape {height, width}
  """
  def polar_grid(width, height, cx, cy, radius) do
    # Create coordinate grids using Nx.iota
    # axis: 0 means values increase along rows (y direction)
    # axis: 1 means values increase along columns (x direction)
    y_coords = Nx.iota({height, width}, axis: 0, type: :f64)
    x_coords = Nx.iota({height, width}, axis: 1, type: :f64)

    # Compute normalized displacements from center
    ux = Nx.divide(Nx.subtract(x_coords, cx), radius)
    uy = Nx.divide(Nx.subtract(y_coords, cy), radius)

    # Convert to polar: rho = sqrt(x² + y²), theta = atan2(y, x)
    rho = Nx.sqrt(Nx.add(Nx.pow(ux, 2), Nx.pow(uy, 2)))
    theta = Nx.atan2(uy, ux)

    {rho, theta}
  end

  @doc """
  Fit Zernike coefficients to wavefront data using least-squares.

  This is the core analysis function: given a measured wavefront, find
  the Zernike coefficients that best describe it. Each coefficient tells
  you "how much" of that aberration type is present in the wavefront.

  ## Algorithm Overview

  The fitting uses linear least-squares regression:
  1. Sample valid pixels from the wavefront data (subsampled for performance)
  2. Build a "design matrix" A where A[i,j] = value of Zernike j at pixel i
  3. Solve the overdetermined system A * coefficients = wavefront_values
  4. The solution minimizes sum of squared errors

  This works because any wavefront W(rho, theta) can be expressed as:
      W = c0*Z0 + c1*Z1 + c2*Z2 + ... + cn*Zn + noise

  ## Parameters
    - data: 2D tensor of wavefront values (in waves or nm)
    - mask: 2D tensor where 255 indicates valid pixels
    - outside: map with :cx, :cy, :rx keys for the aperture circle
    - num_terms: number of Zernike terms to fit (1 to 49)
    - opts: keyword list of options
      - :max_samples - maximum number of samples (default 10000)

  ## Returns
    List of num_terms coefficients (same units as input data)

  ## Interpretation

  After fitting, each coefficient represents the amount of that aberration:
  - Large Z3 (defocus): focus adjustment needed
  - Large Z4/Z5 (astigmatism): cylindrical error in optic
  - Large Z8 (spherical): mirror figure error (undercorrected vs overcorrected)
  """
  def fit(data, mask, outside, num_terms, opts \\ [])
      when num_terms >= 1 and num_terms <= @max_terms do
    max_samples = Keyword.get(opts, :max_samples, 10000)
    {height, width} = Nx.shape(data)

    cx = outside.cx
    cy = outside.cy
    radius = outside.rx

    # Convert pixel coordinates to polar coordinates for Zernike evaluation
    {rho, theta} = polar_grid(width, height, cx, cy, radius)

    # Create a mask of valid pixels:
    # - mask == 255 means pixel has valid data (not outside aperture)
    # - data != 0 means pixel has actual measurement (not a gap)
    # - rho <= 1 means pixel is inside the normalized aperture
    valid_mask =
      mask
      |> Nx.equal(255)
      |> Nx.logical_and(Nx.not_equal(data, 0.0))
      |> Nx.logical_and(Nx.less_equal(rho, 1.0))

    # Subsample pixels for performance - fitting 10000 pixels is usually
    # sufficient for accurate results, and much faster than fitting millions
    step = compute_sample_step(width, height, max_samples)

    # Create a regular grid subsampling pattern (every Nth pixel)
    y_sample = Nx.iota({height}, type: :s32)
    x_sample = Nx.iota({width}, type: :s32)
    y_keep = Nx.remainder(y_sample, step) |> Nx.equal(0)
    x_keep = Nx.remainder(x_sample, step) |> Nx.equal(0)

    # Combine subsampling grid with validity mask
    sample_mask =
      Nx.outer(y_keep, x_keep)
      |> Nx.as_type(:u8)
      |> Nx.logical_and(valid_mask)

    flat_sample_mask = Nx.flatten(sample_mask)
    num_valid = Nx.sum(flat_sample_mask) |> Nx.to_number() |> round()

    # Need at least as many samples as terms to solve (more is better)
    if num_valid < num_terms do
      List.duplicate(0.0, num_terms)
    else
      flat_rho = Nx.flatten(rho)
      flat_theta = Nx.flatten(theta)
      flat_data = Nx.flatten(data)

      # Extract only the sampled pixel indices
      # argsort with :desc puts true (1) values first
      sample_indices =
        flat_sample_mask
        |> Nx.as_type(:s32)
        |> Nx.argsort(direction: :desc)

      take_indices = Nx.slice(sample_indices, [0], [num_valid])

      # Gather the sampled coordinates and values
      sample_rho = Nx.take(flat_rho, take_indices)
      sample_theta = Nx.take(flat_theta, take_indices)
      sample_vals = Nx.take(flat_data, take_indices)

      # Build design matrix: each row is one pixel, each column is one Zernike term
      # A[i,j] = Zernike polynomial j evaluated at (rho[i], theta[i])
      design_matrix = evaluate(sample_rho, sample_theta, num_terms)

      solve_least_squares(design_matrix, sample_vals, num_terms)
    end
  end

  # Compute subsampling step to limit total samples
  # Returns the step size (every Nth pixel in both dimensions)
  defp compute_sample_step(width, height, max_samples) do
    total_pixels = width * height
    # sqrt because we sample in 2D: step² × (area) ≈ max_samples
    step = :math.sqrt(total_pixels / max_samples) |> ceil() |> round()
    max(1, step)
  end

  # ==========================================================================
  # LEAST-SQUARES SOLVER
  # ==========================================================================
  #
  # Solves the overdetermined linear system:  A * x = b
  # where A is the design matrix (num_samples × num_terms)
  #       x is the unknown coefficients (num_terms × 1)
  #       b is the measured wavefront values (num_samples × 1)
  #
  # Since we have many more samples than unknowns (overdetermined), we use
  # the normal equations:  (A^T × A) × x = A^T × b
  #
  # This minimizes the sum of squared residuals (least-squares solution).
  #
  # Tikhonov regularization (adding small epsilon to diagonal) prevents
  # numerical instability when A^T × A is nearly singular.
  # ==========================================================================
  defp solve_least_squares(design_matrix, values, num_terms) do
    # A^T (transpose of design matrix)
    a_t = Nx.transpose(design_matrix)

    # Normal equation: (A^T × A) × x = A^T × b
    # A^T × A: (num_terms × num_terms)
    ata = Nx.dot(a_t, design_matrix)
    # A^T × b: (num_terms × 1)
    atb = Nx.dot(a_t, values)

    # Tikhonov regularization: add tiny value to diagonal for numerical stability
    # This prevents division-by-zero issues when polynomials are nearly collinear
    regularization = Nx.multiply(Nx.eye(num_terms, type: :f64), 1.0e-10)
    ata_reg = Nx.add(ata, regularization)

    # Solve the linear system using LU decomposition
    solution = Nx.LinAlg.solve(ata_reg, atb)
    Nx.to_flat_list(solution)
  end

  @doc """
  Reconstruct a wavefront surface from Zernike coefficients.

  ## Parameters
    - rho: 2D tensor of normalized radial coordinates
    - theta: 2D tensor of azimuthal angles
    - coefficients: list of Zernike coefficients
    - opts: keyword list of options
      - :enables - map of term_index => boolean to selectively enable terms

  ## Returns
    2D tensor of the reconstructed surface
  """
  def reconstruct(rho, theta, coefficients, opts \\ []) do
    enables = Keyword.get(opts, :enables, nil)
    num_terms = length(coefficients)
    surfaces = compute_surfaces(rho, theta, num_terms)

    effective_coefficients =
      if enables do
        Enum.with_index(coefficients, fn coef, i ->
          if Map.get(enables, i, true), do: coef, else: 0.0
        end)
      else
        coefficients
      end

    {height, width} = Nx.shape(rho)

    Enum.zip(surfaces, effective_coefficients)
    |> Enum.reduce(Nx.broadcast(0.0, {height, width}), fn {surface, coef}, acc ->
      Nx.add(acc, Nx.multiply(surface, coef))
    end)
  end

  @doc """
  Standard optical Zernike term names for display purposes.
  """
  def term_names do
    %{
      0 => "Piston",
      1 => "Tilt X",
      2 => "Tilt Y",
      3 => "Defocus",
      4 => "Astigmatism 0°",
      5 => "Astigmatism 45°",
      6 => "Coma X",
      7 => "Coma Y",
      8 => "Primary Spherical",
      9 => "Trefoil X",
      10 => "Trefoil Y",
      11 => "Secondary Astigmatism 0°",
      12 => "Secondary Astigmatism 45°",
      13 => "Secondary Coma X",
      14 => "Secondary Coma Y",
      15 => "Secondary Spherical",
      16 => "Tetrafoil X",
      17 => "Tetrafoil Y",
      18 => "Secondary Trefoil X",
      19 => "Secondary Trefoil Y",
      20 => "Tertiary Astigmatism 0°",
      21 => "Tertiary Astigmatism 45°",
      22 => "Tertiary Coma X",
      23 => "Tertiary Coma Y",
      24 => "Tertiary Spherical",
      25 => "Pentafoil X",
      26 => "Pentafoil Y",
      27 => "Secondary Tetrafoil X",
      28 => "Secondary Tetrafoil Y",
      29 => "Tertiary Trefoil X",
      30 => "Tertiary Trefoil Y",
      31 => "Quaternary Astigmatism 0°",
      32 => "Quaternary Astigmatism 45°",
      33 => "Quaternary Coma X",
      34 => "Quaternary Coma Y",
      35 => "Quaternary Spherical",
      36 => "Hexafoil X",
      37 => "Hexafoil Y",
      38 => "Secondary Pentafoil X",
      39 => "Secondary Pentafoil Y",
      40 => "Tertiary Tetrafoil X",
      41 => "Tertiary Tetrafoil Y",
      42 => "Quaternary Trefoil X",
      43 => "Quaternary Trefoil Y",
      44 => "Quinary Astigmatism 0°",
      45 => "Quinary Astigmatism 45°",
      46 => "Quinary Coma X",
      47 => "Quinary Coma Y",
      48 => "Quinary Spherical"
    }
  end
end
