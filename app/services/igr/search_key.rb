module Igr
  # Builds an English-friendly phonetic search key from Marathi (Devanagari) text.
  #
  # The scraped data is Marathi, but most building/society names are English words
  # spelled phonetically in Devanagari (हाइट्स = Heights, टॉवर = Tower, रेसिडेन्सी =
  # Residency, मीता = Meeta). So a user typing English can't substring-match the
  # stored Marathi. We bridge that by reducing BOTH the stored text and the typed
  # query to the same consonant skeleton:
  #
  #   1. romanize Devanagari -> Latin consonants (vowels become a dropped placeholder),
  #   2. fold spelling variants (aspirates kh/gh/.., silent -ght, soft c, w/v, x->ks),
  #   3. drop vowels and collapse repeats.
  #
  # "हाइट्स" -> "haits" -> "hts"  and  "Heights" -> "ht" via -ght rule -> "hts".
  # "स्टेटस विहार" -> "stts vhr"  and  "Status Vihar" -> "stts vhr".
  # Matching is fuzzy by design (high recall); the user scans the filtered list.
  module SearchKey
    module_function

    # Devanagari consonant -> Latin. Vowels/matras map to "a" (dropped later), so
    # only the CONSONANTS need to be right.
    DEVANAGARI = {
      "क" => "k", "ख" => "kh", "ग" => "g", "घ" => "gh", "ङ" => "n",
      "च" => "ch", "छ" => "chh", "ज" => "j", "झ" => "jh", "ञ" => "n",
      "ट" => "t", "ठ" => "th", "ड" => "d", "ढ" => "dh", "ण" => "n",
      "त" => "t", "थ" => "th", "द" => "d", "ध" => "dh", "न" => "n",
      "प" => "p", "फ" => "ph", "ब" => "b", "भ" => "bh", "म" => "m",
      "य" => "y", "र" => "r", "ल" => "l", "व" => "v",
      "श" => "sh", "ष" => "sh", "स" => "s", "ह" => "h",
      "ळ" => "l", "क्ष" => "ksh", "ज्ञ" => "gy",
      "क़" => "k", "ख़" => "kh", "ग़" => "g", "ज़" => "z", "ड़" => "r",
      "ढ़" => "rh", "फ़" => "f", "य़" => "y",
      # independent vowels + matras -> "a" placeholder (dropped in #fold)
      "अ" => "a", "आ" => "a", "इ" => "a", "ई" => "a", "उ" => "a", "ऊ" => "a",
      "ऋ" => "a", "ए" => "a", "ऐ" => "a", "ओ" => "a", "औ" => "a", "ऍ" => "a", "ऑ" => "a",
      "ा" => "a", "ि" => "a", "ी" => "a", "ु" => "a", "ू" => "a", "ृ" => "a",
      "े" => "a", "ै" => "a", "ो" => "a", "ौ" => "a", "ॅ" => "a", "ॉ" => "a",
      "ं" => "n", "ँ" => "n", "ः" => "h", "्" => "", "ऽ" => "",
      "०" => "0", "१" => "1", "२" => "2", "३" => "3", "४" => "4",
      "५" => "5", "६" => "6", "७" => "7", "८" => "8", "९" => "9"
    }.freeze

    # Multi-char digraphs folded to a single base consonant (order matters: longer
    # keys first). Aligns Marathi aspirates and English digraphs to one form.
    DIGRAPHS = {
      "chh" => "c", "ksh" => "ks", "kh" => "k", "gh" => "g", "jh" => "j",
      "th" => "t", "dh" => "d", "ph" => "f", "bh" => "b", "sh" => "s", "ch" => "c"
    }.freeze

    # Phonetic key for any text (Devanagari or Latin). Returns space-separated
    # consonant-skeleton tokens, e.g. "स्टेटस विहार" / "Status Vihar" -> "stts vhr".
    def call(text)
      fold(romanize(text))
    end

    # Phonetic key over the fields people actually search by name (building,
    # parties, doc no). The long Marathi property_description is intentionally
    # excluded — it floods short skeletons with noise and stays searchable via the
    # raw Devanagari match in DocumentsController#search.
    def for_document(document)
      call([document.building_name, document.seller_names, document.purchaser_names,
            document.doc_number].compact.join(" "))
    end

    def romanize(text)
      text.to_s.each_char.map { |ch| DEVANAGARI.fetch(ch, ch) }.join
    end

    def fold(latin)
      s = latin.to_s.downcase
      s = s.gsub("ght", "t")              # silent gh: heights/lights
      DIGRAPHS.each { |a, b| s = s.gsub(a, b) }
      s = s.gsub(/c(?=[eiy])/, "s").gsub("c", "k") # soft c -> s, else k
      s = s.gsub("x", "ks").gsub("w", "v")
      s = s.gsub(/[aeiouy]/, "")          # drop vowels (incl. semivowel y)
      s = s.gsub(/(.)\1+/, '\1')          # collapse repeats
      s.gsub(/[^a-z0-9 ]/, " ").squeeze(" ").strip
    end
  end
end
