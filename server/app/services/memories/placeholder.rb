module Memories
  # Placeholder words standing in for a memory's text in an operator session: the same number of
  # words and lines, so the page looks as it does to the person, and none of their words.
  module Placeholder
    WORDS = %w[lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut
               labore et dolore magna aliqua enim ad minim veniam quis nostrud exercitation ullamco].freeze

    module_function

    def words_like(text)
      return text if text.nil?

      n = -1
      text.to_s.split("\n", -1).map { |line| line.split.map { WORDS[(n += 1) % WORDS.size] }.join(" ") }.join("\n")
    end
  end
end
