require "digest"

# A MusicBrainz ID Last.fm reported inconsistently for the same plays (see the migration). One row
# per level and exact strings: the artist name, plus the album or track name. Candidate IDs
# accumulate across validations, for investigating later; nothing here is ever picked as the ID.
class MbidDispute < ApplicationRecord
  include HistoryStorage

  LEVELS = %w[artist album track].freeze
  # The variant's name that identifies each level, besides the artist name.
  TITLE_FIELDS = { "artist" => nil, "album" => :album_name, "track" => :track_name }.freeze

  belongs_to :first_import_window, class_name: "ImportWindow", optional: true

  validates :level, inclusion: { in: LEVELS }

  def self.hash_for(level, artist_name, title)
    Digest::SHA256.digest(JSON.generate([ level, artist_name, title ]))
  end

  # The strings that identify `level` for a name variant (or anything with its fields).
  def self.strings_for(level, fields)
    title_field = TITLE_FIELDS.fetch(level)
    [ fields[:artist_name], title_field && fields[title_field].to_s ]
  end

  # Levels whose ID is disputed for this variant's exact strings.
  def self.levels_for(variant)
    hashes = LEVELS.to_h { |level| [ hash_for(level, *strings_for(level, variant)), level ] }
    where(strings_hash: hashes.keys).pluck(:strings_hash).map { |h| hashes.fetch(h) }.to_set
  end

  # Records conflicts (Snapshot::IdConflict) from one validation. Safe under concurrency: one row
  # per strings, candidates merged. Existing variants with those strings are queued for matching
  # again, so links made through the disputed ID are revisited (Catalogue::Matcher).
  def self.record!(conflicts, window:, now: Time.current)
    conflicts.group_by { |c| [ c.level, c.artist_name, c.title ] }.each do |(level, artist_name, title), group|
      candidates = group.flat_map(&:mbids)
      dispute = create_or_find_by!(strings_hash: hash_for(level, artist_name, title)) do |d|
        d.assign_attributes(level: level, artist_name: artist_name, title: title, first_import_window: window,
                            first_seen_at: now, last_seen_at: now)
      end
      dispute.lock!
      dispute.update!(candidate_mbids: (dispute.candidate_mbids | candidates).sort, occurrences: dispute.occurrences + group.size,
                      last_seen_at: now)
      requeue_variants(level, artist_name, title)
    end
  end

  def self.requeue_variants(level, artist_name, title)
    scope = NameVariant.where(artist_name: artist_name)
    scope = scope.where(TITLE_FIELDS.fetch(level) => title) if title
    scope.update_all(match_version: nil)
  end
end
