defmodule Amanogawa.Repo do
  use Ecto.Repo,
    otp_app: :amanogawa,
    adapter: Ecto.Adapters.Postgres
end
