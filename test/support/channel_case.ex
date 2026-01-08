defmodule RougailSolsticeWeb.ChannelCase do
  @moduledoc """
  This module defines the test case to be used by
  channel tests.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest
      import RougailSolsticeWeb.ChannelCase

      @endpoint RougailSolsticeWeb.Endpoint
    end
  end

  setup tags do
    RougailSolstice.DataCase.setup_sandbox(tags)
    :ok
  end
end
