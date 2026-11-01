/*
 * Asks runtime/rg_settings_root.h where the settings folders are, a line of standard input each:
 * CONFIG_DIR XDG_CONFIG_HOME HOME LINUX, with "-" for one that is not set and "empty" for one set to
 * nothing. Prints the folder, or "-" for leaving it to the operating system's own place. See
 * test_native_settings_root.rb.
 */
#include <stdio.h>
#include <string.h>
#include "rg_settings_root.h"

static const char *said(const char *word) {
  if (strcmp(word, "-") == 0) return NULL;
  return strcmp(word, "empty") == 0 ? "" : word;
}

int main(void) {
  char config_dir[256], xdg[256], home[256], root[512];
  int linux_system;
  while (scanf("%255s %255s %255s %d", config_dir, xdg, home, &linux_system) == 4) {
    int found = rg_settings_root(root, sizeof root, said(config_dir), said(xdg), said(home), linux_system);
    puts(found ? root : "-");
  }
  return 0;
}
