require "test_helper"

# The shared contract example (docs/milestone-3-plan.md §3): the Overview the backend computes
# for a fixed synthetic history must equal src/test/contract/overview-2014.json, which the
# frontend renders in src/test/contract/contract.test.tsx. If the shape or the rules change, both
# sides see it. Regenerate deliberately with UPDATE_CONTRACT=1.
#
# Catalogue ids depend on database sequences, so they become stable placeholders (`a#1`, ...).
class OverviewContractTest < ActiveSupport::TestCase
  include HistoryHelpers

  FILE = Rails.root.join("../src/test/contract/overview-2014.json")

  def normalize(value, ids = {})
    case value
    when Hash then value.to_h { |k, v| [ k.to_s, normalize(v, ids) ] }
    when Array then value.map { |v| normalize(v, ids) }
    when /\A([atl])\d+\z/ then ids[value] ||= "#{Regexp.last_match(1)}##{ids.count { |k, _| k.start_with?(Regexp.last_match(1)) } + 1}"
    else value
    end
  end

  test "the 2014 Overview of a fixed synthetic history matches the shared example" do
    user = history_user("contract")
    user.update!(reporting_timezone: "Europe/London")
    artists = [ [ "The Contract Band", "8e0bd6b8-0f2f-4e83-9a1c-4a7a3b1f0001" ], [ "Second Artist", "8e0bd6b8-0f2f-4e83-9a1c-4a7a3b1f0002" ],
                [ "Third Artist", "" ] ]
    variants = artists.flat_map do |name, mbid|
      Array.new(4) do |t|
        variant(track: "#{name} Track #{t + 1}", artist: name, album: t.even? ? "#{name} Album" : "", artist_mbid: mbid).tap { |v| Catalogue::Matcher.new.match!(v) }
      end
    end
    unmatched = variant(track: "Untitled", artist: "Not Matched Yet", album: "")
    start = Time.utc(2014, 1, 6, 19)
    300.times do |i|
      v = i % 7 == 6 ? unmatched : variants[((i * 5) + (i / 4)) % variants.size]
      scrobble(user, at: start + (i * 29).hours, variant: v)
    end
    scrobble(user, at: start + (3 * 29).hours, seq: 1, variant: variants.first) # a same-second play
    scrobble(user, at: start + (10 * 29).hours + 1.hour, variant: variants[4]) # the same track again that day: on repeat
    scrobble(user, at: Time.utc(2014, 5, 5, 12), variant: variants.last).update!(removed_at: Time.current) # removed: not counted
    scrobble(user, at: Time.utc(2011, 2, 1, 12), variant: variants[4]) # Second Artist, years earlier
    window(user, from: Time.utc(2014, 1, 1), to: Time.utc(2014, 11, 1), state: "committed", validated_at: Time.current,
                 committed_at: Time.current, committed_count: 0)

    period = Analytics::Period.parse("year:2014", time_zone: user.reporting_timezone, today: Date.new(2026, 10, 31))
    actual = normalize(JSON.parse(Analytics::Overview.new(user: user, period: period).call.to_json))
    if ENV["UPDATE_CONTRACT"] == "1"
      File.write(FILE, "#{JSON.pretty_generate(actual)}\n")
      skip "contract example rewritten"
    end
    assert_equal JSON.parse(File.read(FILE)), actual, "the Overview changed; if intended, run with UPDATE_CONTRACT=1 and check the frontend"
  end
end
