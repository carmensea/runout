module Memories
  # The user's memories as the Memories page shows them (docs/milestone-5-plan.md §4): every one of
  # theirs with its song, or those matching `q` in the text, the label, the song's title or its
  # artist. Songs are read through their merge chains, so a memory written about a track since
  # merged shows under the song it now is. Nobody else's memories can appear: the query starts
  # from the user and never leaves them.
  module Journal
    module_function

    # `redact`: an operator session. The words are placeholders, the search looks only at songs and
    # artists (a search over the words would tell which words a memory holds), and the page is
    # read-only.
    def call(user, q: nil, redact: false)
      scope = user.memories.includes(track: :artist)
      memories = scope.order(created_at: :desc, id: :desc).to_a
      roots = memories.to_h { |m| [ m.id, m.track.resolved ] }
      if q.present?
        needle = q.to_s.strip.downcase
        memories = memories.select do |m|
          root = roots[m.id]
          texts = [ root.title, root.artist.resolved.name ]
          texts += [ m.body, m.remembered_label ] unless redact
          texts.any? { |text| text.to_s.downcase.include?(needle) }
        end
      end
      covers = Songs.artwork(user, roots.values.map(&:id).uniq)
      list = memories.map { |m| Serializer.memory(m, root: roots[m.id], artwork_url: covers[roots[m.id].id], redact: redact) }
      redact ? { memories: list, readOnly: true } : { memories: list }
    end
  end
end
