/*
 * THE SENTENCES A FILE IS REFUSED IN. Every sentence is made once, in Ruby, when the game is built
 * (IR::StartFile#rules, Original::ShellFacts), with {name} where something only the running program
 * knows goes: the size of the file it was handed, the name of the file a player picked. This fills
 * them in, and checks a file against the numbers it must hold, for the game as it starts
 * (rg_start_file_open) and for a shell's kept pack (rg_shell.c) alike. rg_refusal.js is the same,
 * function for function.
 */
#ifndef RG_REFUSAL_H
#define RG_REFUSAL_H

#include <stddef.h>
#include <stdint.h>

/* The most bytes a sentence takes once filled in. */
#define RG_WORDS_ROOM 2048

/* +words+ into +out+ (+room+ bytes), each {name} in it replaced by the value at the same place in
 * +values+ as the name has in +names+ (+count+ of each). A {name} not among them is left as it is. */
void rg_words_fill(char *out, size_t room, const char *words, int count, const char *const *names,
                   const char *const *values);

/* The sentences of IR::StartFile::Words: no file; a file of another size ({size}); a file without
 * the bytes a check names ({from} and {to}, the first and the last of them). */
typedef struct {
  const char *missing;
  const char *wrong_size;
  const char *wrong_check;
} rg_start_file_words;

/* Whether +bytes+ (+size+ of them; NULL for no file) fails the check of +rules+ (IR::StartFile::Rules:
 * the size, how many checks, and each check as where it starts, how long it is and its bytes): 1, with
 * the sentence for why in +out+, or 0. */
int rg_start_file_refusal(const uint8_t *bytes, int32_t size, const int32_t *rules, const rg_start_file_words *words,
                          char *out, size_t room);

#endif
