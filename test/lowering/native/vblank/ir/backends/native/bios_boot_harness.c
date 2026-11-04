/*
 * Drives runtime/rg_bios_boot.c for test_native_bios_boot.rb. Three ways:
 *
 *   program IMAGE STEPS [ADDRESS ...]
 *     Puts the file IMAGE where the BIOS goes (a made-up program a test assembled, never a BIOS), runs
 *     STEPS instructions from address 0, and prints each register ("r0 0x...", up to "pc", then "cpsr"
 *     and "cycles") and the word at each ADDRESS ("mem 0x... 0x...").
 *
 *   boot BIOS ROM FRAMES PICTURES SOUND [MEMORY]
 *     Switches the console on with the player's BIOS and the cartridge ROM (its first bytes and its
 *     size are all it reads) and plays up to FRAMES frames, or until the start-up reaches the
 *     cartridge. Writes each frame's picture to PICTURES
 *     (240 by 160, four bytes a pixel), each frame's sound to SOUND (a 32-bit count of samples, then
 *     that many left and right 16-bit pairs), and with MEMORY each frame's memories there (the work
 *     memories, the colours, the picture's memory, the sprite table and the registers, in that order),
 *     and prints "frames N", "reached_game 0|1", "rate R" and "unhandled ...".
 *
 *   trace BIOS ROM FRAMES STEPS
 *     Plays FRAMES frames, then STEPS instructions, printing for each the address it ran, the cycles
 *     counted, the registers and the status: for finding where the emulator and mGBA part ways.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "rg_bios_boot.h"

static int read_file(const char *path, uint8_t *bytes, size_t room) {
  FILE *file = fopen(path, "rb");
  if (!file) {
    fprintf(stderr, "cannot open %s\n", path);
    return 0;
  }
  size_t got = fread(bytes, 1, room, file);
  fclose(file);
  (void)got;
  return 1;
}

static void print_registers(const rg_bios_boot *boot) {
  for (int i = 0; i < 15; i++) printf("r%d 0x%08X\n", i, rg_bios_boot_register(boot, i));
  printf("pc 0x%08X\n", rg_bios_boot_register(boot, 15));
  printf("cpsr 0x%08X\n", rg_bios_boot_register(boot, 16));
  printf("cycles %llu\n", (unsigned long long)rg_bios_boot_cycles(boot));
}

static uint32_t peek32(const rg_bios_boot *boot, uint32_t address) {
  return (uint32_t)rg_bios_boot_peek(boot, address) | (uint32_t)rg_bios_boot_peek(boot, address + 1) << 8 |
         (uint32_t)rg_bios_boot_peek(boot, address + 2) << 16 | (uint32_t)rg_bios_boot_peek(boot, address + 3) << 24;
}

static int run_program(int argc, char **argv) {
  static uint8_t image[RG_BIOS_BOOT_BIOS_BYTES];
  static const uint8_t cartridge[RG_BIOS_BOOT_CARTRIDGE_BYTES];
  if (argc < 4 || !read_file(argv[2], image, sizeof image)) return 2;
  rg_bios_boot *boot = rg_bios_boot_open(image, cartridge, 0);
  long steps = strtol(argv[3], NULL, 10);
  for (long i = 0; i < steps; i++) rg_bios_boot_step(boot);
  print_registers(boot);
  for (int i = 4; i < argc; i++) {
    uint32_t address = (uint32_t)strtoul(argv[i], NULL, 0);
    printf("mem 0x%08X 0x%08X\n", address, peek32(boot, address));
  }
  printf("unhandled %s\n", rg_bios_boot_unhandled(boot));
  rg_bios_boot_close(boot);
  return 0;
}

static void write_memory(FILE *out, const rg_bios_boot *boot) {
  static const uint32_t starts[] = {0x02000000u, 0x03000000u, 0x05000000u, 0x06000000u, 0x07000000u, 0x04000000u};
  static const uint32_t sizes[] = {0x40000u, 0x8000u, 0x400u, 0x18000u, 0x400u, 0x400u};
  static uint8_t bytes[0x40000];
  for (size_t region = 0; region < sizeof starts / sizeof starts[0]; region++) {
    for (uint32_t i = 0; i < sizes[region]; i++) bytes[i] = rg_bios_boot_peek(boot, starts[region] + i);
    fwrite(bytes, 1, sizes[region], out);
  }
}

static rg_bios_boot *open_with_bios(char **argv) {
  static uint8_t bios[RG_BIOS_BOOT_BIOS_BYTES];
  static uint8_t cartridge[RG_BIOS_BOOT_CARTRIDGE_BYTES];
  if (!read_file(argv[2], bios, sizeof bios) || !read_file(argv[3], cartridge, sizeof cartridge)) return NULL;
  FILE *rom = fopen(argv[3], "rb");
  if (!rom || fseek(rom, 0, SEEK_END) != 0) return NULL;
  long size = ftell(rom);
  fclose(rom);
  return rg_bios_boot_open(bios, cartridge, (uint32_t)size);
}

static int run_boot(int argc, char **argv) {
  if (argc < 7) return 2;
  rg_bios_boot *boot = open_with_bios(argv);
  if (!boot) return 2;
  long frames = strtol(argv[4], NULL, 10);
  FILE *pictures = fopen(argv[5], "wb");
  FILE *sound = fopen(argv[6], "wb");
  FILE *memory = argc > 7 ? fopen(argv[7], "wb") : NULL;
  if (!pictures || !sound) return 2;
  long played = 0;
  int reached = 0;
  while (played < frames) {
    if (!rg_bios_boot_play_frame(boot)) {
      reached = 1;
      break;
    }
    played++;
    fwrite(rg_bios_boot_picture(boot), sizeof(uint32_t), RG_BIOS_BOOT_WIDTH * RG_BIOS_BOOT_HEIGHT, pictures);
    const int16_t *samples;
    uint32_t count = (uint32_t)rg_bios_boot_sound(boot, &samples);
    fwrite(&count, sizeof count, 1, sound);
    fwrite(samples, sizeof(int16_t), 2u * count, sound);
    if (memory) write_memory(memory, boot);
  }
  fclose(pictures);
  fclose(sound);
  if (memory) fclose(memory);
  printf("frames %ld\nreached_game %d\nrate %d\nunhandled %s\n", played, reached, rg_bios_boot_sound_rate(boot),
         rg_bios_boot_unhandled(boot));
  rg_bios_boot_close(boot);
  return 0;
}

static int run_trace(int argc, char **argv) {
  if (argc < 6) return 2;
  rg_bios_boot *boot = open_with_bios(argv);
  if (!boot) return 2;
  long frames = strtol(argv[4], NULL, 10), steps = strtol(argv[5], NULL, 10);
  for (long i = 0; i < frames; i++)
    if (!rg_bios_boot_play_frame(boot)) break;
  for (long i = 0; i < steps; i++) {
    printf("%08X %llu", rg_bios_boot_register(boot, 15), (unsigned long long)rg_bios_boot_cycles(boot));
    for (int r = 0; r < 15; r++) printf(" %08X", rg_bios_boot_register(boot, r));
    printf(" %08X\n", rg_bios_boot_register(boot, 16));
    rg_bios_boot_step(boot);
  }
  rg_bios_boot_close(boot);
  return 0;
}

int main(int argc, char **argv) {
  if (argc < 2) return 2;
  if (strcmp(argv[1], "program") == 0) return run_program(argc, argv);
  if (strcmp(argv[1], "boot") == 0) return run_boot(argc, argv);
  if (strcmp(argv[1], "trace") == 0) return run_trace(argc, argv);
  return 2;
}
