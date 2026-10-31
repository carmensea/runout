# Album artwork reference from the Cover Art Archive (docs/milestone-4-plan.md §10.4): thumbnail URLs
# on approved hosts and where the cover was found, never the image itself.
class MetadataArtwork < ApplicationRecord
  def found? = found_on.present?
end
