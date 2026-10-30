# A bounded UTC range [window_from, window_to) of one user's history, fetched, validated and
# committed as a unit (docs/milestone-2-plan.md §4). Import workers arrive in later stages; this
# model only holds the state and the claiming rules they will rely on.
class ImportWindow < ApplicationRecord
  include HistoryStorage

  STATES = %w[pending fetching validating validated committing committed failed needs_review split].freeze
  # A worker holds a window only while its lease is valid; after a crash the lease expires and
  # another worker may take the window over. Validation renews it after every page, so it only
  # needs to outlast the longest gap between pages (a paced request plus its retry), not a whole
  # fetch; a dead worker is noticed within this time.
  LEASE = 5.minutes
  # States a worker may pick up. `validated` waits for commit (Stage 2.4); `needs_review`, `split`
  # and `committed` are never picked up automatically. `fetching` and `validating` are only taken
  # over once their lease has expired (an interrupted worker).
  CLAIMABLE_STATES = %w[pending failed fetching validating].freeze

  # The worker's lease expired or was taken over; it must stop without writing.
  class StaleLease < StandardError; end

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
  # Imported at least once: counts as coverage even while a later check of the month is running.
  scope :imported, -> { where.not(committed_at: nil) }

  # Automatic retries after a failure, by attempt number. Bounded: past the last one the window
  # stops (`failed` with no retry_at) until someone retries it (HistoryImport::Recovery).
  RETRY_DELAYS = [ 5.minutes, 30.minutes, 2.hours, 6.hours ].freeze

  def self.retry_delay(attempt, retry_after: nil)
    [ RETRY_DELAYS.fetch((attempt - 1).clamp(0, RETRY_DELAYS.size - 1)), retry_after.to_f.seconds ].max
  end

  # Requests counted against the lifetime budget: those since the last manual retry.
  def budget_requests_used = http_requests_used - http_requests_baseline

  def gave_up? = state == "failed" && retry_at.nil?

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

  # Claims the window to fetch and validate it: one conditional UPDATE, so only one worker can win.
  # Takes over an interrupted window once its lease has expired, and counts the attempt.
  def claim_for_validation!(token, now: Time.current)
    ensure_uuid!(token)
    claimed = self.class.where(id: id, state: CLAIMABLE_STATES)
                         .where("claim_token IS NULL OR lease_expires_at < ?", now)
                         .update_all([ "claim_token = ?, lease_expires_at = ?, state = 'fetching', attempts = attempts + 1, updated_at = ?",
                                       token, now + LEASE, now ])
    reload if claimed == 1
    claimed == 1
  end

  # Runs a short transaction only while `token` still holds an unexpired lease: locks the row,
  # renews the lease and yields the window. Raises StaleLease otherwise, before anything is written.
  # Never make network requests inside the block.
  def with_lease(token, now: Time.current)
    ensure_uuid!(token)
    self.class.transaction do
      window = self.class.lock.where(id: id, claim_token: token).where("lease_expires_at > ?", now).first
      raise StaleLease, "lease on window #{id} is no longer held" unless window

      window.lease_expires_at = now + LEASE
      result = yield window
      window.save! if window.changed?
      result
    end
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
