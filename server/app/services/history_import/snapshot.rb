module HistoryImport
  # One complete read of a window: every play Last.fm returned, as a multiset.
  #
  # - Entries keep the exact strings and MBIDs (nothing trimmed or normalised).
  # - Identical plays, same second and same strings, are separate entries, counted and never
  #   collapsed.
  # - Comparison is by content and occurrence count. The order Last.fm returned plays in is kept
  #   only as `position` for staging, and is never used as an identity or for comparison.
  # - Equality compares the full multisets directly, not checksums, so it is collision-free.
  class Snapshot
    Entry = Data.define(:played_at, :artist, :artist_mbid, :track, :track_mbid, :album, :album_mbid) do
      def self.from(scrobble)
        new(played_at: scrobble.played_at, artist: scrobble.artist, artist_mbid: scrobble.artist_mbid,
            track: scrobble.track, track_mbid: scrobble.track_mbid, album: scrobble.album, album_mbid: scrobble.album_mbid)
      end

      def variant_fields
        { artist_name: artist, artist_mbid: artist_mbid, track_name: track, track_mbid: track_mbid,
          album_name: album.to_s, album_mbid: album_mbid }
      end
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

    # Counts only, never contents, so the result is safe to store and log.
    def difference_summary(other)
      mine = multiset
      theirs = other.multiset
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
