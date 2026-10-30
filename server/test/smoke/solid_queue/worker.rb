# A real Solid Queue supervisor (dispatcher, workers, optional scheduler), forked as in production,
# against the smoke database. Started and stopped by run.rb.
require_relative "boot"

# Crash points the driver can switch on: the process kills itself, as an OOM kill would.
HistoryImport::WindowCommitter.prepend(Module.new do
  def call
    if Smoke.control["crash"] == "before_commit" && !Smoke.marked?("crashed")
      Smoke.mark("crashed")
      Process.kill(:KILL, Process.pid)
    end
    super
  end
end)
Scrobble.singleton_class.prepend(Module.new do
  def insert_all!(*args, **options)
    if Smoke.control["crash"] == "during_commit" && !Smoke.marked?("crashed")
      Smoke.mark("crashed")
      Process.kill(:KILL, Process.pid) # inside the commit transaction
    end
    super
  end
end)

# Mirrors config/environments/production.rb.
SolidQueue.shutdown_timeout = ENV.fetch("SOLID_QUEUE_SHUTDOWN_TIMEOUT", 25).to_i.seconds
# Find workers killed outright quickly instead of after 5 minutes.
SolidQueue.process_alive_threshold = 15.seconds

options = { config_file: Rails.root.join("test/smoke/solid_queue/queue.yml") }
if ENV["SMOKE_RECURRING"] == "1"
  options[:recurring_schedule_file] = Rails.root.join("test/smoke/solid_queue/recurring.yml")
else
  options[:skip_recurring] = true
end
SolidQueue::Supervisor.start(**options)
