defmodule RougailSolstice.Repo do
  use Ecto.Repo,
    otp_app: :rougail_solstice,
    adapter: Ecto.Adapters.SQLite3
end
