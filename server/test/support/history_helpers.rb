# Helpers for Milestone 2 schema tests. History storage is off everywhere by default; these tests
# switch it on explicitly, and only with synthetic data.
module HistoryHelpers
  extend ActiveSupport::Concern

  included do
    setup do
      @history_flag = Rails.configuration.x.history_import_enabled
      Rails.configuration.x.history_import_enabled = "true"
    end
    teardown { Rails.configuration.x.history_import_enabled = @history_flag }
  end

  # Postgres aborts the surrounding transaction on a failed statement, so expected rejections run
  # inside a savepoint and the test can continue afterwards.
  def assert_db_rejects(error = ActiveRecord::StatementInvalid, &block)
    assert_raises(error) { ActiveRecord::Base.transaction(requires_new: true, &block) }
  end

  def history_user(name = "listener")
    User.create!(display_name: name)
  end

  def variant(track: "Track", artist: "Artist", album: "Album", **mbids)
    NameVariant.for!(artist_name: artist, track_name: track, album_name: album, **mbids)
  end

  def scrobble(user, at:, seq: 0, variant: self.variant)
    Scrobble.create!(user: user, played_at: at, seq: seq, name_variant: variant)
  end

  def window(user, from:, to:, state: "pending", **attrs)
    ImportWindow.create!(user: user, window_from: from, window_to: to, state: state, **attrs)
  end

  def fetch(window, attempt: 1, **attrs)
    window.fetches.create!(attempt: attempt, started_at: Time.current, **attrs)
  end

  # A play as the snapshot fetcher would produce it. Exact strings; MBIDs default to blank.
  def entry(at, track = "Track", artist: "Artist", album: "Album", artist_mbid: "", track_mbid: "", album_mbid: "")
    HistoryImport::Snapshot::Entry.new(played_at: at, artist: artist, artist_mbid: artist_mbid, track: track,
                                       track_mbid: track_mbid, album: album, album_mbid: album_mbid)
  end

  # Puts a window in the state WindowValidator leaves it in: a validated fetch with the snapshot
  # staged, and the window `validated` with matching counts. No Last.fm requests.
  def stage!(window, entries, at: Time.current)
    snapshot = HistoryImport::Snapshot.new(entries: entries, reported_total: entries.size, total_pages: 1)
    attempt = (window.fetches.maximum(:attempt) || 0) + 1
    f = fetch(window, attempt: attempt, outcome: "validated", expected_total: entries.size, row_count: entries.size, finished_at: at)
    rows = snapshot.staging_rows.map { |row| row.merge(import_window_fetch_id: f.id) }
    ImportWindowRow.insert_all!(rows) if rows.any?
    window.update!(state: "validated", validated_at: at, expected_total: entries.size, fetched_count: entries.size)
    f
  end
end
