/*
 * A PORT BUILT AS A SHELL, ON A COMPUTER (Original::Shell has what a shell is; rg_shell.c is the
 * flow, and rg_shell.js the same written again for a page, function for function). The program
 * holds none of the original's data. It is built with its parts in a folder beside it: the game
 * itself, and under parts/ the menu and one unpacking for each release of the original the game
 * reads. Each part is a whole desktop program of its own, since the native lowering names every
 * global of one program for the runtime and two programs cannot share one executable.
 *
 * rg_shell_facts is Original::ShellFacts, what every runtime of a shell is made from
 * (Native::ShellData writes it), every sentence a file is refused in among them, each with {name}
 * where rg_words_fill puts what only the running program knows. A build that is no shell has none
 * (NULL), and nothing here runs.
 */
#ifndef RG_SHELL_H
#define RG_SHELL_H

#include <stddef.h>
#include <stdint.h>

#include "rg_refusal.h"

/* One file of a release that is several files (Original::ReleaseFile). */
typedef struct {
  const char *name; /* as the original's disks spell it; a folder's may differ in case */
  const char *sha1;
  int32_t size;
} rg_shell_file;

typedef struct {
  const char *name;
  const char *sha1;         /* 40 lowercase hex digits */
  int32_t size;             /* in bytes, or -1 where it is not known */
  int read;                 /* whether the game reads this release */
  const char *part;         /* the file under parts/ that unpacks it, "" for a release not read */
  const char *unread_words; /* {named}: a copy of a release not read; "" for one that is */
  const rg_shell_file *files; /* a release that is several files: its files, in its order; NULL for one file */
  int file_count;
} rg_shell_release;

typedef struct {
  const char *title;
  const char *folder;    /* the game's folder among the files the computer keeps for each program */
  const char *pack_file; /* the pack's name in it */
  const rg_shell_release *releases;
  int release_count;
  const char *wrong_size_words; /* {named} and {size}: a file no release is the size of */
  const char *unknown_words;    /* {named} and {sha1}: a file that is no release the game knows */
  const char *one_file_words;   /* {named}: one file, where every release read is a folder; "" otherwise */
  const char *folder_words;     /* {named}: a folder, where no release read is one; "" otherwise */
  const char *lacking_words;    /* {named} and {lacking}: a folder that holds no release whole */
  const char *release_lacks_words; /* {release} and {missing}: one release's part of {lacking} */
  const char *wrong_file_words; /* {named}, {release}, {want_size}, {want_sha1}, {size}, {sha1} */
  const char *lacking_join;     /* between releases in {lacking} */
  const char *missing_join;     /* between file names in {missing} */
  const uint8_t *pack_before_sha1; /* the pack's header before the copy's SHA-1 */
  int pack_before_sha1_size;
  const uint8_t *pack_after_sha1; /* ...and after it */
  int pack_after_sha1_size;
  const int32_t *pack_rules; /* the check of a kept pack, as rg_start_file_refusal takes it */
  rg_start_file_words pack_words;
  const char *menu_part;       /* the file under parts/ that plays the menu */
  const char *choice_variable; /* the menu's variable, and what each number in it means */
  int load_rom;
  int settings;
  const char *bytes_list; /* the unpacking's list of the pack's bytes, and its two variables */
  const char *finished_variable;
  const char *fault_kind_variable;
  const char *kept_pack_refused_words; /* {path} and {refusal} */
  const char *unpacking_stopped_words; /* {named} and {fault} */
  const char *unreadable_words;        /* {named} and {why} */
} rg_shell_description;

extern const rg_shell_description *const rg_shell_facts;

/* What a test names in place of what a person does (--shell-copy, --shell-menu-keys,
 * --shell-settings-keys), and where the pack is kept where the player has not chosen
 * (--pack-folder). All NULL for a player's run. */
typedef struct {
  const char *pack_folder;
  const char *copy;          /* the file picked, in place of the file dialog */
  const char *menu_keys;     /* a script of buttons the menu is played with, in place of a person */
  const char *settings_keys; /* ...and the one once SETTINGS has opened the window's menu */
} rg_shell_asked;

/* The path of a data pack this shell reads, made from the player's copy if it was not kept yet; NULL
 * when the player stopped. Frees with SDL_free. A test that names a copy this shell refuses ends
 * the program here, printing why. */
char *rg_shell_pack_path(const rg_shell_asked *asked);

#endif
