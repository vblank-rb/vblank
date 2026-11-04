/*
 * THE CONSOLE'S OWN START-UP, PLAYED FROM THE PLAYER'S BIOS (rg_bios_boot.c).
 *
 * A Game Boy Advance, switched on, runs the small program built into it (the BIOS) before the
 * cartridge: it draws the Nintendo logo, plays the chime, checks the cartridge's header, and then
 * jumps to the game. A desktop build of an Advance game does the same when the player has their own
 * copy of the BIOS (rg_console_bios.h finds it): rg_bios_boot.c is a small emulator of exactly the
 * parts of the console that program touches, and it runs the BIOS's own code. Nothing of the BIOS is
 * in VBlank: the file is read where the player keeps it, each time the game starts.
 *
 * The window plays it a frame at a time before the game's first frame, shows each picture and plays
 * each frame's sound, and starts the game once the BIOS reaches the cartridge. The windowless program
 * and the checked runs never play it.
 *
 * The answer key is mGBA, playing the same BIOS with the same cartridge header: every picture and
 * every sample of sound is held to it (test_native_bios_boot.rb). Where mGBA and the console differ,
 * mGBA is what this follows, so the comparison can be exact.
 */
#ifndef RG_BIOS_BOOT_H
#define RG_BIOS_BOOT_H

#include <stdint.h>

#define RG_BIOS_BOOT_BIOS_BYTES 16384

/* How much of the cartridge the start-up reads: its 192-byte header, which carries the logo the BIOS
 * checks, and the next few words, which it copies. The cartridge is given as its first this many
 * bytes, and the size of the whole of it. */
#define RG_BIOS_BOOT_CARTRIDGE_BYTES 256
#define RG_BIOS_BOOT_WIDTH 240
#define RG_BIOS_BOOT_HEIGHT 160

/* Where the cartridge's code starts: the start-up is over when the processor gets there. */
#define RG_BIOS_BOOT_CARTRIDGE_ENTRY 0x08000000u

/* The most samples of sound one frame makes. The console mixes its sound at 32,768 samples a second
 * unless the program asks for more (rg_bios_boot_sound_rate); at the most it can ask, 262,144 a
 * second, a frame is under 4,400. */
#define RG_BIOS_BOOT_SOUND_MOST 4608

typedef struct rg_bios_boot rg_bios_boot;

/* A console switched on with +bios+ (RG_BIOS_BOOT_BIOS_BYTES) in it and the game's cartridge, given
 * as its first RG_BIOS_BOOT_CARTRIDGE_BYTES bytes, +cartridge+, and its size in bytes, +rom_size+:
 * the BIOS checks the logo and the header's check byte, and stops if they are wrong. NULL when there
 * is no memory for it. */
rg_bios_boot *rg_bios_boot_open(const uint8_t *bios, const uint8_t *cartridge, uint32_t rom_size);
void rg_bios_boot_close(rg_bios_boot *boot);

/* Plays one frame: from where the last one ended to the moment the next picture is finished (the
 * start of the gap below the screen, as mGBA counts a frame). Gives 1 when it played a whole frame,
 * and 0 once the processor has reached the cartridge's code, when the start-up is over and the frame
 * it was part way through is not shown. */
int rg_bios_boot_play_frame(rg_bios_boot *boot);

/* The picture the last frame drew, 240 by 160, a 32-bit colour each: red in the low byte, then
 * green, then blue, and the top byte 0 (SDL_PIXELFORMAT_XBGR8888). Eight bits a colour, worked out
 * the way mGBA works them out, so a picture can be held to its picture exactly. */
const uint32_t *rg_bios_boot_picture(const rg_bios_boot *boot);

/* The sound the last frame made: how many samples, with *+samples+ pointed at them, the left and the
 * right side by side. Each is the console's mix of its voices as mGBA mixes them, before anything
 * changes its rate for a speaker. */
int rg_bios_boot_sound(const rg_bios_boot *boot, const int16_t **samples);

/* How many samples a second the sound is mixed at now. */
int rg_bios_boot_sound_rate(const rg_bios_boot *boot);

/* How many frames have been played. */
long rg_bios_boot_frames(const rg_bios_boot *boot);

/* --- for the tests (test_native_bios_boot.rb and its harness), which hold the emulator itself to
 * the processor and to mGBA. A game's window uses none of these. --- */

/* Runs one instruction, with whatever the console does in the time it takes (the screen, the
 * timers, the copies, an interrupt). A processor asleep until an interrupt sleeps until one, or
 * until the next thing the console does, instead. */
void rg_bios_boot_step(rg_bios_boot *boot);

/* Register +n+ (0 to 14) of the mode the processor is in, the address of the instruction it runs
 * next (15), or its status register (16). */
uint32_t rg_bios_boot_register(const rg_bios_boot *boot, int n);

/* The cycles counted since the console was switched on. */
uint64_t rg_bios_boot_cycles(const rg_bios_boot *boot);

/* The byte at +address+ as the console holds it, read without doing anything a read would do. */
uint8_t rg_bios_boot_peek(const rg_bios_boot *boot, uint32_t address);

/* The first thing the program asked of the console that this emulator does not do, in words, or ""
 * when there has been nothing. What the start-up uses is all done, so a test holds this to "". */
const char *rg_bios_boot_unhandled(const rg_bios_boot *boot);

#endif
