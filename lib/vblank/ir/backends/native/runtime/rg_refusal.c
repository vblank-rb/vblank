/* The sentences a file is refused in (rg_refusal.h says what they are). */
#include "rg_refusal.h"

#include <stdio.h>
#include <string.h>

void rg_words_fill(char *out, size_t room, const char *words, int count, const char *const *names,
                   const char *const *values) {
  size_t used = 0;
  if (room == 0) return;
  for (const char *at = words; *at && used + 1 < room;) {
    const char *value = NULL;
    size_t taken = 1;
    if (*at == '{') {
      for (int i = 0; i < count && !value; i++) {
        size_t length = strlen(names[i]);
        if (strncmp(at + 1, names[i], length) == 0 && at[1 + length] == '}') {
          value = values[i];
          taken = length + 2;
        }
      }
    }
    if (value) {
      size_t length = strlen(value);
      if (length > room - 1 - used) length = room - 1 - used;
      memcpy(out + used, value, length);
      used += length;
    } else {
      out[used++] = *at;
    }
    at += taken;
  }
  out[used] = '\0';
}

int rg_start_file_refusal(const uint8_t *bytes, int32_t size, const int32_t *rules, const rg_start_file_words *words,
                          char *out, size_t room) {
  if (!bytes) {
    snprintf(out, room, "%s", words->missing);
    return 1;
  }
  if (size != rules[0]) {
    char size_text[16];
    snprintf(size_text, sizeof size_text, "%d", (int)size);
    const char *names[] = {"size"};
    const char *values[] = {size_text};
    rg_words_fill(out, room, words->wrong_size, 1, names, values);
    return 1;
  }
  const int32_t *check = rules + 2;
  for (int32_t each = 0; each < rules[1]; each++) {
    int32_t at = check[0];
    int32_t length = check[1];
    for (int32_t i = 0; i < length; i++) {
      if (bytes[at + i] != (uint8_t)check[2 + i]) {
        char from[16], to[16];
        snprintf(from, sizeof from, "%d", (int)at);
        snprintf(to, sizeof to, "%d", (int)(at + length - 1));
        const char *names[] = {"from", "to"};
        const char *values[] = {from, to};
        rg_words_fill(out, room, words->wrong_check, 2, names, values);
        return 1;
      }
    }
    check += 2 + length;
  }
  return 0;
}
