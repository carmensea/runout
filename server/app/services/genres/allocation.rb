module Genres
  # Genre figures for a set of plays (docs/backend-plan.md §6, docs/milestone-4-plan.md §3). Every
  # play counts exactly once, split over its item's broad genres by the item's shares, or wholly to
  # Unclassified. So allocated plays add up to the plays counted, and shares (allocated plays over
  # plays) add up to exactly 1, Unclassified included.
  #
  # Reach is a different number: the plays by items with any weight in a genre. A play counts towards
  # every genre its item has, so reach overlaps and must never be summed or stacked.
  module Allocation
    Totals = Data.define(:plays, :broad, :sub, :reach) do
      # Shares of all plays: { slug => 0..1 }, adding up to 1 (Unclassified included).
      def broad_shares = shares(broad)
      def sub_shares = shares(sub)
      def reach_shares = shares(reach)

      private

      def shares(h) = plays.zero? ? {} : h.transform_values { |n| n.to_f / plays }
    end

    # `items`: [[plays, Classifier::Result], ...] (one entry per artist, or per artist and year).
    def self.call(items)
      plays = 0
      broad = Hash.new(0.0)
      sub = Hash.new(0.0)
      reach = Hash.new(0)
      items.each do |n, result|
        plays += n
        result.broad.each { |slug, share| broad[slug] += n * share }
        result.sub.each { |slug, share| sub[slug] += n * share }
        result.present.each { |slug| reach[slug] += n }
      end
      Totals.new(plays: plays, broad: broad, sub: sub, reach: reach)
    end

    # Whole percentages that add up to exactly 100 (largest remainder), for `shares` adding up to 1.
    def self.whole_percentages(shares)
      return {} if shares.empty?

      exact = shares.transform_values { |s| s * 100 }
      floors = exact.transform_values(&:floor)
      missing = 100 - floors.values.sum
      exact.sort_by { |slug, v| [ -(v - v.floor), slug ] }.first([ missing, 0 ].max).each { |slug, _| floors[slug] += 1 }
      floors
    end
  end
end
