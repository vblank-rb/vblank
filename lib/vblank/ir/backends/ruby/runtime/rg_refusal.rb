# THE SENTENCES A FILE IS REFUSED IN (the native runtime's rg_refusal.h has what they are, and this
# is rg_refusal.c written again, function for function).

# +words+ with each {name} in it that +values+ (a Hash by Symbol) has replaced by its value. A
# {name} it does not have is left as it is.
def rg_words_fill(words, values)
  words.gsub(/\{(\w+)\}/) do |whole|
    name = ::Regexp.last_match(1).to_sym
    values.key?(name) ? values[name].to_s : whole
  end
end

# The sentence for why +bytes+ (a String, or nil for no file) fails the check of +rules+
# (IR::StartFile::Rules), or nil. +words+ holds the three sentences: :missing, :wrong_size and
# :wrong_check.
def rg_start_file_refusal(bytes, rules, words)
  return words[:missing] if bytes.nil?
  return rg_words_fill(words[:wrong_size], { size: bytes.bytesize }) if bytes.bytesize != rules[0]

  check = 2
  rules[1].times do
    at = rules[check]
    length = rules[check + 1]
    if bytes.byteslice(at, length).bytes != rules[check + 2, length]
      return rg_words_fill(words[:wrong_check], { from: at, to: at + length - 1 })
    end

    check += 2 + length
  end
  nil
end
