defmodule Amanogawa.Ingestion.Workers.RunGuard do
  @moduledoc """
  Last-line guard shared by the ingestion workers: when an exception
  escapes a worker's `perform/1` on its *final* Oban attempt, the
  referenced `Amanogawa.Ingestion.SyncRun` is closed `:failed` (with the
  formatted exception as `last_error`) before the exception is re-raised.
  Without this, a crash on the last attempt would leave the run `:running`
  forever, unresumable and blocking any new run of the same kind.

  `try/rescue` is legitimate here: this is the system boundary between
  Oban's execution model (which only sees the exception) and the run's
  persisted state (which must reflect reality). The close itself is also
  guarded, so a database failure being the very cause of the crash never
  masks the original exception behind a second one.
  """

  require Logger

  alias Amanogawa.Ingestion.SyncRun
  alias Amanogawa.Repo

  @doc """
  Closes the job's sync run `:failed` when `job` is on its final attempt
  and the run is still `:running`. A no-op otherwise (earlier attempts, a
  run already closed, or a run that cannot be loaded). Never raises.
  """
  @spec close_failed_on_final_attempt(Oban.Job.t(), Exception.t(), module()) :: :ok
  def close_failed_on_final_attempt(
        %Oban.Job{attempt: attempt, max_attempts: max_attempts, args: args},
        exception,
        worker
      ) do
    if attempt >= max_attempts do
      case Repo.get(SyncRun, args["sync_run_id"]) do
        %SyncRun{status: :running} = sync_run ->
          sync_run
          |> SyncRun.close_changeset(%{
            status: :failed,
            last_error: Exception.format(:error, exception)
          })
          |> Repo.update!()

          :ok

        _closed_or_missing ->
          :ok
      end
    else
      :ok
    end
  rescue
    close_exception ->
      Logger.error(
        "#{inspect(worker)} could not close its sync run after a crash: " <>
          Exception.message(close_exception)
      )

      :ok
  end
end
