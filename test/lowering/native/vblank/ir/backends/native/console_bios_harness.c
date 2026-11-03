/*
 * Asks runtime/rg_console_bios.h for the player's BIOS, a line of standard input each, its fields
 * divided by tabs: ENVIRONMENT SETTING SHARED_FOLDER KNOWN_SHA1, with "-" for one that is not set and
 * "empty" for one set to nothing. Prints "none", "found<TAB>PATH" or "refused<TAB>PATH<TAB>MESSAGE".
 * See test_native_console_bios.rb.
 */
#include <stdio.h>
#include <string.h>
#include "rg_console_bios.h"

static const char *said(const char *word) {
  if (strcmp(word, "-") == 0) return NULL;
  return strcmp(word, "empty") == 0 ? "" : word;
}

int main(void) {
  char line[4096];
  while (fgets(line, sizeof line, stdin)) {
    line[strcspn(line, "\n")] = '\0';
    const char *fields[4];
    char *rest = line;
    for (int i = 0; i < 4; i++) {
      fields[i] = rest;
      char *tab = strchr(rest, '\t');
      if (tab) {
        *tab = '\0';
        rest = tab + 1;
      }
    }
    const char *known[] = {fields[3]};
    char path[1024], message[2048];
    switch (rg_console_bios_find(said(fields[0]), said(fields[1]), said(fields[2]), known, 1, path, sizeof path, message,
                                 sizeof message)) {
    case RG_CONSOLE_BIOS_NONE: puts("none"); break;
    case RG_CONSOLE_BIOS_FOUND: printf("found\t%s\n", path); break;
    case RG_CONSOLE_BIOS_REFUSED: printf("refused\t%s\t%s\n", path, message); break;
    }
  }
  return 0;
}
