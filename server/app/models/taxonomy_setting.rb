# Tuning values for genre classification (docs/backend-plan.md §6): `min_tag_weight`, `min_mapped_weight`.
class TaxonomySetting < ApplicationRecord
  self.primary_key = "key"

  DEFAULTS = { "min_tag_weight" => 10, "min_mapped_weight" => 10 }.freeze

  def self.values = DEFAULTS.merge(pluck(:key, :value).to_h { |k, v| [ k, v.to_f ] })
end
