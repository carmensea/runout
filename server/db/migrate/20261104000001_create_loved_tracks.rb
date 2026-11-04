# Loved songs (docs/loved-songs.md): a person's favourites, owned by Runout. One row per user, song
# (a name variant: the exact strings and MusicBrainz IDs the source sent) and source. Last.fm's
# loved list is imported read-only; `runout` rows are favourites made here. A refresh from Last.fm
# only ever adds rows or sets `unloved_at` on untouched `lastfm` rows; `manual` rows and `runout`
# rows are never changed by it. Separate from scrobbles: a favourite is not a play.
#
# Additive only.
class CreateLovedTracks < ActiveRecord::Migration[8.1]
  def change
    create_table :loved_tracks do |t|
      t.references :user, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :name_variant, null: false, foreign_key: true
      t.string :source, null: false                 # lastfm, runout
      t.datetime :loved_at, null: false             # when the song was loved, as the source reports it
      t.text :source_url                            # the source's page for the song
      t.datetime :first_imported_at
      t.datetime :last_listed_at                    # the last complete source list that included it
      t.datetime :unloved_at                        # no longer loved; the row and its history stay
      t.boolean :manual, null: false, default: false # changed by a person here: refreshes leave it alone
      t.timestamps
      t.index [ :user_id, :name_variant_id, :source ], unique: true, name: "index_loved_tracks_identity"
      t.index [ :user_id, :loved_at ]
      t.check_constraint "source IN ('lastfm', 'runout')", name: "loved_tracks_source"
    end
  end
end
