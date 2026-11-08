module Memories
  # A memory as the API gives it: the song at the end of its merge chain, the text, the memory's own
  # dates and when it was written and last edited.
  module Serializer
    module_function

    # `redact`: an operator session; the words become placeholders of the same shape (Placeholder).
    def memory(m, root: m.track.resolved, artwork_url: nil, redact: false)
      { id: m.id, song: { id: "t#{root.id}", name: root.title, artist: { id: "a#{root.artist.resolved.id}", name: root.artist.resolved.name }, artworkUrl: artwork_url },
        body: redact ? Placeholder.words_like(m.body) : m.body, rememberedOn: m.remembered_on&.iso8601,
        rememberedLabel: redact ? Placeholder.words_like(m.remembered_label) : m.remembered_label,
        createdAt: m.created_at.utc.iso8601, updatedAt: m.updated_at.utc.iso8601 }
    end
  end
end
