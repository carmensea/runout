module Loved
  # Imports a user's Last.fm loved list into `loved_tracks` (docs/loved-songs.md). Read-only towards
  # Last.fm. Safe to repeat: a song already here is kept with its original loved date; one Last.fm no
  # longer lists is marked `unloved_at`, but only after the whole list was fetched and its size
  # matched what Last.fm announced, so a failed or short response can never unlove anything.
  # `runout` rows and `manual` rows are never changed.
  #
  # Each song becomes a name variant (the exact strings and MusicBrainz IDs Last.fm sent, no album)
  # and goes through the catalogue matcher like any play: a MusicBrainz ID links the recording, a
  # disputed ID is ignored, a name alone joins the name-only entity, and what fits several entities is
  # held for review. Nothing about existing plays, variants or catalogue rows changes.
  class Import
    class Incomplete < StandardError; end

    PAGE_SIZE = 1000
    Report = Data.define(:listed, :added, :kept, :reloved, :unloved, :manual_skipped, :malformed, :linked, :review, :unlinked)

    def initialize(user:, client: Lastfm::Config.client, matcher: Catalogue::Matcher.new, now: -> { Time.current })
      @user = user
      @client = client
      @matcher = matcher
      @now = now
    end

    def run!
      username = @user.lastfm_identity&.uid or raise Incomplete, "no Last.fm identity for this user"
      rows, malformed = fetch_all!(username)
      stamp = @now.call
      tally = Hash.new(0)
      ListeningStorage.writing_for("lastfm_loved") do
        rows.each { |row| tally[merge(row, stamp)] += 1 }
        tally[:unloved] = LovedTrack.lastfm.where(user: @user, manual: false, unloved_at: nil).where("last_listed_at < ?", stamp).update_all(unloved_at: stamp, updated_at: stamp)
      end
      states = LovedTrack.lastfm.current.where(user: @user).joins(:name_variant).group("name_variants.track_match").count
      Report.new(listed: rows.size, added: tally[:added], kept: tally[:kept], reloved: tally[:reloved], unloved: tally[:unloved],
                 manual_skipped: tally[:manual_skipped], malformed: malformed,
                 linked: states.sum { |match, n| NameVariant::LINKED_MATCHES.include?(match) ? n : 0 },
                 review: states.fetch("ambiguous", 0), unlinked: states.sum { |match, n| match.nil? || match == "unmatched" ? n : 0 })
    end

    private

    # Every page, then the count check. Last.fm can return a song twice across page boundaries while
    # the list changes: the earliest loved date is kept.
    def fetch_all!(username)
      first = @client.loved_tracks(username: username, page: 1, limit: PAGE_SIZE)
      pages = [ first ]
      (2..first.total_pages.to_i).each { |n| pages << @client.loved_tracks(username: username, page: n, limit: PAGE_SIZE) }
      tracks = pages.flat_map(&:tracks)
      malformed = pages.sum(&:malformed_count)
      raise Incomplete, "Last.fm announced #{first.total} loved tracks, #{tracks.size + malformed} received" unless first.total && tracks.size + malformed == first.total

      [ tracks.group_by { |t| [ t.artist_name, t.artist_mbid, t.track_name, t.track_mbid ] }.values.map { |same| same.min_by(&:loved_at) }, malformed ]
    end

    def merge(row, stamp)
      variant = NameVariant.for!(artist_name: row.artist_name, artist_mbid: row.artist_mbid, track_name: row.track_name, track_mbid: row.track_mbid, album_name: "")
      @matcher.match!(variant) if variant.match_version.nil? || variant.match_version < Catalogue::Matcher::VERSION
      loved = LovedTrack.find_by(user: @user, name_variant: variant, source: "lastfm")
      if loved.nil?
        LovedTrack.create!(user: @user, name_variant: variant, source: "lastfm", loved_at: row.loved_at, source_url: row.url,
                           first_imported_at: stamp, last_listed_at: stamp)
        :added
      elsif loved.manual
        :manual_skipped
      elsif loved.unloved_at
        loved.update!(loved_at: row.loved_at, unloved_at: nil, last_listed_at: stamp, source_url: row.url || loved.source_url)
        :reloved
      else
        loved.update!(last_listed_at: stamp, loved_at: [ loved.loved_at, row.loved_at ].min)
        :kept
      end
    end
  end
end
