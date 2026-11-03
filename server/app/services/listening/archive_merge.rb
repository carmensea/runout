module Listening
  # Merges an ArchiveExport file into this database (docs/railway-deployment.md §6). Every play goes
  # through the normal Recorder, so the archive's own matching rules decide it: already stored, a
  # second report of a Last.fm play (linked), a person's decision (held), or a new play. Safe to
  # repeat. Never edits a Last.fm play or catalogue row; what can't be applied is reported.
  #
  # Runs on a copy: it refuses the development database, and the database must be named on the
  # command line.
  class ArchiveMerge
    class Refused < StandardError; end

    PROTECTED_DATABASES = %w[runout_development].freeze
    Report = Data.define(:tally, :conflicts, :other_decisions, :held_for_review)

    def initialize(path) = @path = path

    def run!(confirm_database:)
      database = ApplicationRecord.connection.current_database
      raise Refused, "#{database} is protected: merge into a copy" if PROTECTED_DATABASES.include?(database)
      raise Refused, "CONFIRM_DATABASE must name #{database}" unless confirm_database == database

      records = read!
      header = records.fetch("header").first
      source = ListeningSource.find_by(provider: header["provider"], external_account_id: header["account"]) or
        raise Refused, "no #{header["provider"]} source here for that account"

      @tally = Hash.new(0)
      @conflicts = []
      @source = source
      ListeningStorage.writing_for(source.provider) do
        records.fetch("observation", []).sort_by { |o| o["reported_at_raw"] }.each { |o| merge_observation(o) }
        records.fetch("decision", []).each { |d| merge_decision(d) }
        records.fetch("poll", []).each { |p| merge_poll(p["row"]) }
        records.fetch("gap", []).each { |g| merge_gap(g) }
        merge_source_state(header)
      end
      Report.new(tally: @tally, conflicts: @conflicts, other_decisions: records.fetch("other_decision", []),
                 held_for_review: ListeningObservation.where(listening_source: source).pending_review.count)
    end

    private

    def read!
      lines = File.readlines(@path, chomp: true)
      trailer = JSON.parse(lines.pop.to_s)
      body = Digest::SHA256.new
      lines.each { |line| body << line }
      raise Refused, "the export is truncated or altered" unless trailer["type"] == "end" && trailer["lines"] == lines.size && trailer["sha256"] == body.hexdigest

      records = lines.map { |line| JSON.parse(line) }.group_by { |r| r["type"] }
      raise Refused, "unknown export format" unless records.fetch("header").first["format"] == ArchiveExport::FORMAT

      records
    end

    def merge_observation(row)
      @conflicts << "#{row["source_event_id"]}: removed in the export" if row["scrobble_removed_at"]
      received = Time.iso8601(row["received_at"])
      existing = ListeningObservation.find_by(listening_source_id: @source.id, source_event_id: row["source_event_id"])
      if existing
        existing.update!(received_at: [ existing.received_at, received ].min, last_seen_at: [ existing.last_seen_at, Time.iso8601(row["last_seen_at"]) ].max,
                         times_seen: [ existing.times_seen, row["times_seen"] ].max, later_values: existing.later_values.presence || row["later_values"])
        @tally[:already_present] += 1
      else
        result = Recorder.new(@source, now: -> { received }).record!(event(row))
        result.observation.update!(last_seen_at: Time.iso8601(row["last_seen_at"]), times_seen: row["times_seen"], later_values: row["later_values"])
        @tally[result.outcome] += 1
      end
    end

    def event(row)
      Event.new(provider: @source.provider, source_event_id: row["source_event_id"], reported_at: Time.iso8601(row["reported_at_raw"]).utc,
                reported_at_raw: row["reported_at_raw"], timestamp_kind: row["timestamp_kind"], duration_ms: row["duration_ms"],
                artist_name: row["artist_name"], track_name: row["track_name"], album_name: row["album_name"],
                provider_track_id: row["provider_track_id"], provider_album_id: row["provider_album_id"],
                provider_artist_ids: row["provider_artist_ids"], isrc: row["isrc"], context: row["context"])
    end

    # A person's decision stands only where the archive reaches the same question. Otherwise the
    # archive holds more evidence than the person saw, so it goes back to a person.
    def merge_decision(row)
      observation = ListeningObservation.find_by!(listening_source_id: @source.id, source_event_id: row["source_event_id"])
      decided_at = Time.iso8601(row["created_at"])
      scope = ReviewDecision.where(subject_type: "ListeningObservation", subject_id: observation.id, action: row["action"], created_at: decided_at)
      return @tally[:decisions_already_present] += 1 if scope.exists?

      if row["action"] == "kept_separate" && observation.link_state == "pending_review"
        Review.separate!(observation, by: @source.user, at: decided_at, carried: row["details"])
        @tally[:decisions_applied] += 1
      elsif row["action"] == "kept_separate" && observation.link_state == "created"
        ReviewDecision.create!(user_id: observation.user_id, subject_type: "ListeningObservation", subject_id: observation.id, action: row["action"],
                               source: row["source"], details: row["details"], created_at: decided_at)
        @tally[:decisions_applied] += 1
      else
        @conflicts << "#{row["source_event_id"]}: decided #{row["action"]} there, #{observation.link_state} here"
      end
    end

    def merge_poll(row)
      return if @source.polls.exists?(started_at: row["started_at"])

      @source.polls.create!(row.merge("user_id" => @source.user_id))
      @tally[:polls_added] += 1
    end

    def merge_gap(record)
      row = record["row"]
      return if @source.gaps.exists?(gap_from: row["gap_from"], gap_to: row["gap_to"])

      poll = record["poll_started_at"] && @source.polls.find_by(started_at: record["poll_started_at"])
      @source.gaps.create!(row.merge("user_id" => @source.user_id, "listening_poll_id" => poll&.id))
      @tally[:gaps_added] += 1
    end

    def merge_source_state(header)
      times = ->(ours, theirs) { [ ours, theirs && Time.iso8601(theirs) ].compact }
      @source.update!(covered_from: times.call(@source.covered_from, header["covered_from"]).min,
                      high_water_at: times.call(@source.high_water_at, header["high_water_at"]).max,
                      last_new_play_at: times.call(@source.last_new_play_at, header["last_new_play_at"]).max,
                      plays_added: ListeningObservation.where(listening_source: @source, link_state: "created").count)
    end
  end
end
