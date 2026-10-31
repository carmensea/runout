module HistoryImport
  # One complete read of a window: every play Last.fm returned, as a multiset.
  #
  # - Entries keep the exact strings and MBIDs (nothing trimmed or normalised).
  # - A play is identified by its second and its exact artist, track and album strings
  #   (`play_key`). MusicBrainz IDs are enrichment, not identity: Last.fm can report different
  #   recording IDs for the same play from one request to the next.
  # - Identical plays, same second and same strings, are separate entries, counted and never
  #   collapsed.
  # - Comparison is by content and occurrence count. The order Last.fm returned plays in is kept
  #   only as `position` for staging, and is never used as an identity or for comparison.
  # - Equality compares the full multisets directly, not checksums, so it is collision-free.
  class Snapshot
    ID_FIELDS = { "artist" => :artist_mbid, "album" => :album_mbid, "track" => :track_mbid }.freeze

    # An ID two equivalent reads disagree on, for the plays at one second with one set of strings.
    # `mbids`: every candidate either read gave (a read may have given none).
    IdConflict = Data.define(:level, :artist_name, :title, :played_at, :mbids)

    Entry = Data.define(:played_at, :artist, :artist_mbid, :track, :track_mbid, :album, :album_mbid) do
      def self.from(scrobble)
        new(played_at: scrobble.played_at, artist: scrobble.artist, artist_mbid: scrobble.artist_mbid,
            track: scrobble.track, track_mbid: scrobble.track_mbid, album: scrobble.album, album_mbid: scrobble.album_mbid)
      end

      def variant_fields
        { artist_name: artist, artist_mbid: artist_mbid, track_name: track, track_mbid: track_mbid,
          album_name: album.to_s, album_mbid: album_mbid }
      end

      # The play itself, without the IDs Last.fm attached to it.
      def play_key = [ played_at, artist, track, album.to_s ]
    end

    attr_reader :entries, :reported_total, :total_pages, :undated_count, :malformed_count, :out_of_window_count

    def initialize(entries:, reported_total:, total_pages:, undated_count: 0, malformed_count: 0, out_of_window_count: 0)
      @entries = entries.freeze
      @reported_total = reported_total
      @total_pages = total_pages
      @undated_count = undated_count
      @malformed_count = malformed_count
      @out_of_window_count = out_of_window_count
    end

    def size = entries.size

    # Entry => number of occurrences.
    def multiset
      @multiset ||= entries.tally
    end

    def same_contents?(other)
      multiset == other.multiset
    end

    # play_key => number of occurrences.
    def plays
      @plays ||= entries.map(&:play_key).tally
    end

    # The same plays, the same number of times, whatever the IDs.
    def equivalent?(other)
      plays == other.plays
    end

    # For an equivalent later read: that read, in its order, with every ID the two reads disagree
    # on removed, and the conflicts. An ID is kept where both reads give the same IDs for the
    # plays at that second with those strings (as a multiset, since identical plays can't be told
    # apart); otherwise it is unresolved for all of them. Nothing is picked between candidates.
    # Returns [snapshot, conflicts].
    def settle_ids(later)
      raise ArgumentError, "the reads have different plays" unless equivalent?(later)

      mine = entries.group_by(&:play_key)
      theirs = later.entries.group_by(&:play_key)
      conflicts = []
      unresolved = theirs.to_h do |key, group|
        ours = mine.fetch(key)
        fields = ID_FIELDS.select { |_, field| ours.map(&field).tally != group.map(&field).tally }
        fields.each do |level, field|
          title = { "artist" => nil, "album" => key[3], "track" => key[2] }.fetch(level)
          group.size.times do
            conflicts << IdConflict.new(level: level, artist_name: key[1], title: title, played_at: key[0],
                                        mbids: (ours + group).filter_map(&field).uniq.sort)
          end
        end
        [ key, fields.values ]
      end
      settled = later.entries.map do |entry|
        fields = unresolved.fetch(entry.play_key)
        fields.empty? ? entry : entry.with(**fields.index_with(nil))
      end
      [ Snapshot.new(entries: settled, reported_total: later.reported_total, total_pages: later.total_pages,
                     undated_count: later.undated_count, malformed_count: later.malformed_count,
                     out_of_window_count: later.out_of_window_count), conflicts ]
    end

    # Counts only, never contents, so the result is safe to store and log. Compares plays, not IDs.
    def difference_summary(other)
      mine = plays
      theirs = other.plays
      only_here = mine.sum { |entry, count| [ count - theirs.fetch(entry, 0), 0 ].max }
      only_there = theirs.sum { |entry, count| [ count - mine.fetch(entry, 0), 0 ].max }
      { only_in_first: only_here, only_in_second: only_there, first_size: size, second_size: other.size }
    end

    # Rows ready for staging: `position` is the order within the second as returned; `occurrence`
    # numbers identical plays within the second, so duplicates stay distinct.
    def staging_rows
      positions = Hash.new(0)
      occurrences = Hash.new(0)
      entries.map do |entry|
        second = entry.played_at.to_i
        position = positions[second]
        positions[second] += 1
        occurrence = occurrences[entry]
        occurrences[entry] += 1
        fields = entry.variant_fields
        {
          played_at: entry.played_at, position: position, occurrence: occurrence,
          variant_hash: NameVariant.hash_for(fields), **fields
        }
      end
    end
  end
end
