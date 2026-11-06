/*
 * THE SENTENCES A FILE IS REFUSED IN (the native runtime's rg_refusal.h says what they are, and this
 * is rg_refusal.c written again, function for function). A page carries it in each game, for
 * rg_start_file_open, and once beside them for a shell's kept pack (rg_shell.js).
 */

/* +words+ with each {name} in it that +values+ (an object) has replaced by its value. A {name} it
 * does not have is left as it is. */
function rg_words_fill(words, values) {
  return words.replace(/\{(\w+)\}/g, (whole, name) => (Object.prototype.hasOwnProperty.call(values, name) ? String(values[name]) : whole));
}

/* The sentence for why +bytes+ (a Uint8Array, or null for no file) fails the check of +rules+
 * (IR::StartFile::Rules: the size, how many checks, and each check as where it starts, how long it
 * is and its bytes), or null. +words+ holds the three sentences, missing, wrong_size and wrong_check. */
function rg_start_file_refusal(bytes, rules, words) {
  if (bytes === null) return words.missing;
  if (bytes.length !== rules[0]) return rg_words_fill(words.wrong_size, { size: bytes.length });
  let check = 2;
  for (let each = 0; each < rules[1]; each++) {
    const at = rules[check], length = rules[check + 1];
    for (let i = 0; i < length; i++) {
      if (bytes[at + i] !== rules[check + 2 + i]) return rg_words_fill(words.wrong_check, { from: at, to: at + length - 1 });
    }
    check += 2 + length;
  }
  return null;
}
