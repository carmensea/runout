# A memory: what a song means to one person, in their own words (docs/milestone-5-plan.md §4).
# Belongs to exactly one user and one catalogue track; read through the track's merge chain
# (Memories::Songs), so a later merge moves it with the song. Three dates stay distinct:
# `remembered_on` / `remembered_label` (what time the memory is about, either, both or neither),
# `created_at` (when written) and `updated_at` (last edit). Private only.
class Memory < ApplicationRecord
  BODY_MAX = 20_000
  LABEL_MAX = 80
  VISIBILITIES = %w[private].freeze

  belongs_to :user
  belongs_to :track

  validates :body, presence: true, length: { maximum: BODY_MAX }
  validates :remembered_label, length: { maximum: LABEL_MAX }, allow_nil: true
  validates :visibility, inclusion: { in: VISIBILITIES }

  # Never in logs or inspect output.
  def inspect = "#<Memory id=#{id.inspect} user_id=#{user_id.inspect} track_id=#{track_id.inspect}>"
end
