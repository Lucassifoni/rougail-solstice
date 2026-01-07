defmodule RougailSolstice.Robot.CameraAdapter.Virtual do
  @moduledoc """
  Virtual camera adapter that returns a random preset image.
  """

  @behaviour RougailSolstice.Robot.CameraAdapter

  @preset_images [
    "/images/preset_1.jpg",
    "/images/preset_2.jpg",
    "/images/preset_3.jpg",
    "/images/preset_4.jpg",
    "/images/preset_5.jpg"
  ]

  @preset_previews [
    "/images/preview_1.jpg",
    "/images/preview_2.jpg",
    "/images/preview_3.jpg"
  ]

  @impl true
  def capture do
    {:ok, Enum.random(@preset_images)}
  end

  @impl true
  def capture_preview do
    {:ok, Enum.random(@preset_previews)}
  end

  @impl true
  def name, do: "Virtual"

  def preset_images, do: @preset_images
end
