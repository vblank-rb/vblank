/*
 * WHERE A PLAYER'S SETTINGS FOLDERS ARE. Settings are something a person keeps and looks after, so
 * they go where that person's computer keeps such things, not with a game's saves: the folder the
 * player named with --config-dir, or vblank's folder in $XDG_CONFIG_HOME, or on Linux in ~/.config.
 * The XDG rules say a path that does not start from the root is to be ignored. A Mac or Windows
 * with none of those keeps them in the operating system's own place for each program, which SDL
 * finds.
 *
 * This is a file of its own, with nothing of SDL in it, so the rule can be tested as plain text
 * (test_native_settings_root.rb). `vblank run` shares these files, and Live::SettingsFile.root is
 * this rule again in Ruby, held to the same table.
 */
#ifndef RG_SETTINGS_ROOT_H
#define RG_SETTINGS_ROOT_H

#include <stdio.h>

/* Writes the folder that holds the settings folders into +root+ (+room+ bytes) and gives 1, or gives
 * 0 for leaving it to the operating system's own place, as it does for a name too long to hold.
 * Any of the three names may be NULL. */
static inline int rg_settings_root(char *root, size_t room, const char *config_dir, const char *xdg_config_home,
                                   const char *home, int linux_system) {
  int written;
  if (config_dir && config_dir[0]) written = snprintf(root, room, "%s", config_dir);
  else if (xdg_config_home && xdg_config_home[0] == '/') written = snprintf(root, room, "%s/vblank", xdg_config_home);
  else if (linux_system && home && home[0]) written = snprintf(root, room, "%s/.config/vblank", home);
  else return 0;
  return written > 0 && (size_t)written < room;
}

#endif
