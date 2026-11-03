/*
 * THE PLAYER'S GAME BOY ADVANCE BIOS, for the console's own start-up picture and sound before a game
 * on the desktop. The BIOS is the small program built into every console, and the start-up (the logo
 * and its chime) is something it draws and plays. It is Nintendo's work, so VBlank never carries it:
 * a game reads it from the player's own computer each time it starts, and a player without one gets
 * no start-up at all, with nothing said.
 *
 * It is looked for in three places, the first that names a file winning: the environment variable
 * VBLANK_GBA_BIOS, a line in the settings file, and gba_bios.bin in the settings folder every game
 * shares, "(all games)" (rg_settings_root.h says where that is). A file named by the first two that is
 * not there is said, since the player asked for it; one simply not in the shared folder is not.
 *
 * A file is used only when its SHA-1 is one VBlank knows, so a damaged file, another console's BIOS or
 * a replacement BIOS is refused in plain words rather than played into a black screen. The SHA-1 is
 * worked out here (a few dozen lines of the published algorithm), since the runtime takes no library
 * for one checksum of one small file.
 *
 * This is a file of its own, with nothing of SDL in it, so the rule can be tested as plain text
 * (test_native_console_bios.rb). `vblank run` finds the same file, and Live::ConsoleBIOS is this rule
 * again in Ruby, held to the same table and the same words.
 */
#ifndef RG_CONSOLE_BIOS_H
#define RG_CONSOLE_BIOS_H

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

/* The retail Game Boy Advance BIOS, 16384 bytes. The SHA-1 is the one both of these give:
 *   MAME, src/mame/nintendo/gba.cpp, ROM_START( gba ):
 *     ROM_LOAD( "gba.bin", 0x000000, 0x004000, CRC(81977335) SHA1(300c20df...) )
 *   libretro-database, dat/System.dat, "Nintendo - Game Boy Advance":
 *     rom ( name gba_bios.bin size 16384 crc 81977335 md5 a860e8c0... sha1 300c20df... )
 * (libretro's mGBA page gives the same MD5, a860e8c0b6d573d191e4ec7db1b1e4f6.) */
#define RG_CONSOLE_BIOS_RETAIL_SHA1 "300c20df6731a33952ded8c436f7f186d25d3492"
#define RG_CONSOLE_BIOS_SIZE_IN_BYTES 16384
#define RG_CONSOLE_BIOS_FILE_NAME "gba_bios.bin"
#define RG_CONSOLE_BIOS_ENVIRONMENT_VARIABLE "VBLANK_GBA_BIOS"
#define RG_CONSOLE_BIOS_NO_START_UP_SENTENCE " The game starts without the start-up picture of the console."

typedef enum { RG_CONSOLE_BIOS_NONE, RG_CONSOLE_BIOS_FOUND, RG_CONSOLE_BIOS_REFUSED } rg_console_bios_answer;

static inline uint32_t rg_sha1_rotate_left(uint32_t value, unsigned bits) {
  return (value << bits) | (value >> (32u - bits));
}

/* One 64-byte block into the five words of the running SHA-1 (FIPS 180-4, section 6.1.2). */
static inline void rg_sha1_add_block(uint32_t sum[5], const unsigned char *block) {
  uint32_t words[80];
  for (unsigned i = 0; i < 16; i++)
    words[i] = (uint32_t)block[4 * i] << 24 | (uint32_t)block[4 * i + 1] << 16 | (uint32_t)block[4 * i + 2] << 8 |
               (uint32_t)block[4 * i + 3];
  for (unsigned i = 16; i < 80; i++)
    words[i] = rg_sha1_rotate_left(words[i - 3] ^ words[i - 8] ^ words[i - 14] ^ words[i - 16], 1);

  uint32_t a = sum[0], b = sum[1], c = sum[2], d = sum[3], e = sum[4];
  for (unsigned i = 0; i < 80; i++) {
    uint32_t mixed, constant;
    if (i < 20) {
      mixed = (b & c) | (~b & d);
      constant = 0x5A827999u;
    } else if (i < 40) {
      mixed = b ^ c ^ d;
      constant = 0x6ED9EBA1u;
    } else if (i < 60) {
      mixed = (b & c) | (b & d) | (c & d);
      constant = 0x8F1BBCDCu;
    } else {
      mixed = b ^ c ^ d;
      constant = 0xCA62C1D6u;
    }
    uint32_t next = rg_sha1_rotate_left(a, 5) + mixed + e + constant + words[i];
    e = d;
    d = c;
    c = rg_sha1_rotate_left(b, 30);
    b = a;
    a = next;
  }
  sum[0] += a;
  sum[1] += b;
  sum[2] += c;
  sum[3] += d;
  sum[4] += e;
}

/* The SHA-1 of +length+ bytes at +data+, as 40 lowercase hex digits and a NUL in +hex+. */
static inline void rg_sha1_hex(const unsigned char *data, size_t length, char hex[41]) {
  uint32_t sum[5] = {0x67452301u, 0xEFCDAB89u, 0x98BADCFEu, 0x10325476u, 0xC3D2E1F0u};
  size_t whole_blocks = length / 64;
  for (size_t i = 0; i < whole_blocks; i++) rg_sha1_add_block(sum, data + 64 * i);

  /* The end: what is left, a 1 bit, zeros, and the length in bits in the last eight bytes. */
  unsigned char tail[128] = {0};
  size_t left = length - 64 * whole_blocks;
  memcpy(tail, data + 64 * whole_blocks, left);
  tail[left] = 0x80;
  size_t tail_length = left + 9 <= 64 ? 64 : 128;
  uint64_t bits = (uint64_t)length * 8u;
  for (unsigned i = 0; i < 8; i++) tail[tail_length - 1 - i] = (unsigned char)(bits >> (8 * i));
  rg_sha1_add_block(sum, tail);
  if (tail_length == 128) rg_sha1_add_block(sum, tail + 64);

  for (unsigned i = 0; i < 20; i++)
    snprintf(hex + 2 * i, 3, "%02x", (unsigned)((sum[i / 4] >> (24 - 8 * (i % 4))) & 0xFFu));
}

/* Whether the file at +path+ can be played from, with the words when not in +message+. +named_by+ says
 * what named the path, or is NULL for the shared folder, where no file is no BIOS rather than a
 * mistake. */
static inline rg_console_bios_answer rg_console_bios_judge(const char *path, const char *named_by,
                                                           const char *const *known_sha1, size_t known_count,
                                                           char *message, size_t room) {
  errno = 0;
  FILE *file = fopen(path, "rb");
  if (!file) {
    if (errno == ENOENT && !named_by) return RG_CONSOLE_BIOS_NONE;
    if (errno == ENOENT)
      snprintf(message, room,
               "VBlank cannot find %s. %s gives this path for the Game Boy Advance BIOS. Make sure that the path is "
               "correct." RG_CONSOLE_BIOS_NO_START_UP_SENTENCE,
               path, named_by);
    else
      snprintf(message, room, "VBlank cannot read %s." RG_CONSOLE_BIOS_NO_START_UP_SENTENCE, path);
    return RG_CONSOLE_BIOS_REFUSED;
  }
  unsigned char bytes[RG_CONSOLE_BIOS_SIZE_IN_BYTES + 1];
  size_t read = fread(bytes, 1, sizeof bytes, file);
  int failed = ferror(file);
  fclose(file);
  if (failed) {
    snprintf(message, room, "VBlank cannot read %s." RG_CONSOLE_BIOS_NO_START_UP_SENTENCE, path);
    return RG_CONSOLE_BIOS_REFUSED;
  }
  if (read != RG_CONSOLE_BIOS_SIZE_IN_BYTES) {
    snprintf(message, room,
             "VBlank cannot use %s as the Game Boy Advance BIOS. The file is not %d bytes long. A Game Boy Advance "
             "BIOS is %d bytes long." RG_CONSOLE_BIOS_NO_START_UP_SENTENCE,
             path, RG_CONSOLE_BIOS_SIZE_IN_BYTES, RG_CONSOLE_BIOS_SIZE_IN_BYTES);
    return RG_CONSOLE_BIOS_REFUSED;
  }

  char sha1[41];
  rg_sha1_hex(bytes, read, sha1);
  for (size_t i = 0; i < known_count; i++)
    if (strcmp(sha1, known_sha1[i]) == 0) return RG_CONSOLE_BIOS_FOUND;

  int written = snprintf(message, room,
                         "VBlank cannot use %s as the Game Boy Advance BIOS. The SHA-1 checksum of the file is %s. "
                         "VBlank uses only a BIOS with the SHA-1 checksum ",
                         path, sha1);
  for (size_t i = 0; i < known_count && written >= 0 && (size_t)written < room; i++)
    written += snprintf(message + written, room - (size_t)written, "%s%s", i ? " or " : "", known_sha1[i]);
  if (written >= 0 && (size_t)written < room)
    snprintf(message + written, room - (size_t)written, "." RG_CONSOLE_BIOS_NO_START_UP_SENTENCE);
  return RG_CONSOLE_BIOS_REFUSED;
}

/* Looks for the BIOS: +environment+ is VBLANK_GBA_BIOS's value, +setting+ the settings file's,
 * +shared_folder+ the folder every game's settings share, each NULL when there is none. Writes the
 * path looked at into +path+ (+path_room+ bytes) and, when it is refused, the words into +message+.
 * +known_sha1+ is the checksums accepted: RG_CONSOLE_BIOS_RETAIL_SHA1, or a test's own. */
static inline rg_console_bios_answer rg_console_bios_find(const char *environment, const char *setting,
                                                          const char *shared_folder, const char *const *known_sha1,
                                                          size_t known_count, char *path, size_t path_room,
                                                          char *message, size_t message_room) {
  const char *named_by = NULL;
  int written;
  if (environment && environment[0]) {
    named_by = "The environment variable " RG_CONSOLE_BIOS_ENVIRONMENT_VARIABLE;
    written = snprintf(path, path_room, "%s", environment);
  } else if (setting && setting[0]) {
    named_by = "The settings file";
    written = snprintf(path, path_room, "%s", setting);
  } else if (shared_folder) {
    written = snprintf(path, path_room, "%s/" RG_CONSOLE_BIOS_FILE_NAME, shared_folder);
  } else {
    return RG_CONSOLE_BIOS_NONE;
  }
  if (written < 0 || (size_t)written >= path_room) return RG_CONSOLE_BIOS_NONE; /* no path that long is found */
  return rg_console_bios_judge(path, named_by, known_sha1, known_count, message, message_room);
}

#endif
