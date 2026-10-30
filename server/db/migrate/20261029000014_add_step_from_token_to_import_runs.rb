# The job token that started the current step. A redelivered job (Solid Queue releases unfinished
# jobs on a graceful shutdown) may take over its own interrupted step once that step is provably
# dead, instead of stopping and leaving the run for the watchdog.
class AddStepFromTokenToImportRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :import_runs, :step_from_token, :uuid
  end
end
