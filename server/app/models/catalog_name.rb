# Name normalisation for catalogue matching (docs/milestone-2-plan.md §6.4): Unicode NFKC,
# case-folded, trimmed, inner whitespace collapsed. Used only to *find candidates*; the original
# strings are always kept, and the schema never makes normalised names unique.
module CatalogName
  module_function

  def normalize(name)
    name.to_s.unicode_normalize(:nfkc).downcase(:fold).strip.gsub(/\s+/, " ")
  end
end
