# The covers fetched so far were all due for their refresh on the same two days (180 days after
# the two fetch days). Under the new policy (Metadata::Artwork::REFRESH + REFRESH_SPREAD) each
# finished release comes due two years after its last success, at its own moment within the two
# months after that, so no batch returns as one wave. Data only; nothing is fetched.
class SpreadArtworkRefreshes < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      UPDATE metadata_targets
         SET next_attempt_at = last_success_at + interval '2 years' + (random() * interval '60 days')
       WHERE provider = 'coverartarchive' AND status = 'ok' AND last_success_at IS NOT NULL
    SQL
  end

  def down
    execute <<~SQL
      UPDATE metadata_targets
         SET next_attempt_at = last_success_at + interval '180 days'
       WHERE provider = 'coverartarchive' AND status = 'ok' AND last_success_at IS NOT NULL
    SQL
  end
end
