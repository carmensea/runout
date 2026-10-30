# A bounded UTC range [window_from, window_to) of one user's history, fetched, validated and
# committed as a unit (docs/milestone-2-plan.md §4). Import workers arrive in later stages; this
# model only holds the state and the claiming rules they will rely on.
class ImportWindow < ApplicationRecord
  include HistoryStorage

  STATES = %w[pending fetching validating validated committing committed failed needs_review split].freeze
  # A worker holds a window only while its lease is valid; after a crash the lease expires and
  # another worker may take the window over.
  LEASE = 30.minutes

  belongs_to :user
  belongs_to :import_run, optional: true
  belongs_to :parent_window, class_name: "ImportWindow", optional: true
  has_many :child_windows, class_name: "ImportWindow", foreign_key: :parent_window_id, inverse_of: :parent_window,
                           dependent: :destroy
  has_many :fetches, class_name: "ImportWindowFetch", dependent: :destroy

  validates :state, inclusion: { in: STATES }
  validates :window_from, :window_to, presence: true
  validate :range_is_ordered

  scope :live, -> { where.not(state: "split") }
  scope :committed, -> { where(state: "committed") }

  UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

  # Atomically claims the window for one worker. Returns true only for the caller that wins; a
  # second worker gets false while the lease is valid. Works across processes (single UPDATE).
  # The token must be a UUID: anything else would be silently stored as NULL by the uuid column,
  # leaving the window looking unclaimed.
  def claim!(token, now: Time.current)
    ensure_uuid!(token)
    claimed = self.class.where(id: id)
                         .where("claim_token IS NULL OR lease_expires_at < ?", now)
                         .update_all(claim_token: token, lease_expires_at: now + LEASE, updated_at: now)
    reload if claimed == 1
    claimed == 1
  end

  def release!(token)
    ensure_uuid!(token)
    self.class.where(id: id, claim_token: token).update_all(claim_token: nil, lease_expires_at: nil, updated_at: Time.current)
  end

  private

  def ensure_uuid!(token)
    raise ArgumentError, "claim token must be a UUID" unless token.to_s.match?(UUID)
  end

  def range_is_ordered
    errors.add(:window_to, "must be after window_from") if window_from && window_to && window_from >= window_to
  end
end
