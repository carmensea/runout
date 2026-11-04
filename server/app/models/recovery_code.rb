# Single-use sign-in codes, stored as SHA-256 digests like session tokens. A set of ten is made
# with the first passkey and shown once; regenerating replaces the whole set.
class RecoveryCode < ApplicationRecord
  COUNT = 10
  # No 0/o, 1/l/i: the codes are typed by hand.
  ALPHABET = %w[a b c d e f g h j k m n p q r s t u v w x y z 2 3 4 5 6 7 8 9].freeze

  belongs_to :user

  scope :unused, -> { where(used_at: nil) }

  # Returns the plaintext codes, the only time they exist outside the person's password manager.
  def self.regenerate!(user)
    transaction do
      where(user: user).delete_all
      Array.new(COUNT) do
        code = Array.new(10) { ALPHABET.sample(random: SecureRandom) }.join.insert(5, "-")
        create!(user: user, code_digest: digest(code))
        code
      end
    end
  end

  # The user the code belongs to, marking it used; nil for an unknown or spent code.
  def self.redeem!(code)
    row = unused.find_by(code_digest: digest(code))
    return nil unless row && row.class.where(id: row.id, used_at: nil).update_all(used_at: Time.current) == 1

    row.user
  end

  def self.digest(code)
    OpenSSL::Digest::SHA256.hexdigest(code.to_s.downcase.gsub(/[^a-z0-9]/, ""))
  end
end
