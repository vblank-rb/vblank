/*
 * A SMALL GAME BOY ADVANCE, JUST BIG ENOUGH TO RUN THE CONSOLE'S OWN START-UP (rg_bios_boot.h).
 *
 * The start-up is a program inside the console, the BIOS, and the only faithful way to show it is to
 * run it. So this is an emulator of what that program touches and nothing more: the processor (an
 * ARM7TDMI, with both of its instruction sets, ARM and THUMB), the memories, the interrupts, the
 * timers and the copy engines (DMA), the picture (two turning backgrounds, sprites, the windows and
 * the blending), and the two recorded-sound voices the chime plays on. The cartridge is only its
 * first RG_BIOS_BOOT_CARTRIDGE_BYTES bytes, the header and a little after it, which the BIOS reads to
 * check the logo; once the processor reaches the cartridge's code, the start-up is over and the game
 * takes the window.
 *
 * mGBA is the answer key (test_native_bios_boot.rb plays the same BIOS in it, frame by frame), so
 * where the console and mGBA disagree, or the console's own behaviour is not known, this does what
 * mGBA does: the cycles each instruction and each memory takes, the moment each event lands, the
 * order the picture is composed in, the way colours are worked out in eight bits. Nothing of mGBA's
 * code is here; what is here is the behaviour, written out again.
 *
 * HOW TIME IS KEPT. Everything that happens on its own — a line of the screen ending, a timer running
 * out, a copy moving a word, an interrupt arriving — is an event at a moment on the console's clock.
 * The processor runs whole instructions, each adding the cycles it took; whenever the clock passes
 * the next event, the events due are done, in the order of their moments (and, at the same moment,
 * a fixed order of kinds), before the next instruction. An instruction is never cut in half by an
 * event: one that straddles the moment a line is drawn wrote its register before the line or after
 * the whole instruction, never between.
 */
#include "rg_bios_boot.h"

#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* --- the console's memory map: the top byte of an address marks which memory it is --- */

enum {
  REGION_BIOS = 0x0,
  REGION_EWRAM = 0x2,   /* the 256K work memory outside the processor */
  REGION_IWRAM = 0x3,   /* the 32K quick work memory inside it */
  REGION_IO = 0x4,      /* the registers */
  REGION_PALETTE = 0x5, /* the colours */
  REGION_VRAM = 0x6,    /* the picture's memory: tiles, maps, sprite tiles */
  REGION_OAM = 0x7,     /* the sprite table */
  REGION_CART0 = 0x8,
  REGION_CART_SRAM = 0xE,
  REGION_CART_SRAM_MIRROR = 0xF
};

#define SIZE_BIOS 0x4000u
#define SIZE_EWRAM 0x40000u
#define SIZE_IWRAM 0x8000u
#define SIZE_IO 0x400u
#define SIZE_PALETTE 0x400u
#define SIZE_VRAM 0x18000u
#define SIZE_OAM 0x400u
#define SIZE_CART0 0x02000000u

/* --- registers, by their offset from 0x04000000 --- */

enum {
  REG_DISPCNT = 0x000,
  REG_GREENSWP = 0x002,
  REG_DISPSTAT = 0x004,
  REG_VCOUNT = 0x006,
  REG_BG0CNT = 0x008,
  REG_BG3CNT = 0x00E,
  REG_BG0HOFS = 0x010,
  REG_BG3VOFS = 0x01E,
  REG_BG2PA = 0x020,
  REG_BG2PB = 0x022,
  REG_BG2PC = 0x024,
  REG_BG2PD = 0x026,
  REG_BG2X_LO = 0x028,
  REG_BG2X_HI = 0x02A,
  REG_BG2Y_LO = 0x02C,
  REG_BG2Y_HI = 0x02E,
  REG_BG3PA = 0x030,
  REG_BG3PB = 0x032,
  REG_BG3PC = 0x034,
  REG_BG3PD = 0x036,
  REG_BG3X_LO = 0x038,
  REG_BG3X_HI = 0x03A,
  REG_BG3Y_LO = 0x03C,
  REG_BG3Y_HI = 0x03E,
  REG_WIN0H = 0x040,
  REG_WIN1H = 0x042,
  REG_WIN0V = 0x044,
  REG_WIN1V = 0x046,
  REG_WININ = 0x048,
  REG_WINOUT = 0x04A,
  REG_MOSAIC = 0x04C,
  REG_BLDCNT = 0x050,
  REG_BLDALPHA = 0x052,
  REG_BLDY = 0x054,
  REG_SOUND1CNT_LO = 0x060,
  REG_SOUND1CNT_HI = 0x062,
  REG_SOUND1CNT_X = 0x064,
  REG_SOUND2CNT_LO = 0x068,
  REG_SOUND2CNT_HI = 0x06C,
  REG_SOUND3CNT_LO = 0x070,
  REG_SOUND3CNT_HI = 0x072,
  REG_SOUND3CNT_X = 0x074,
  REG_SOUND4CNT_LO = 0x078,
  REG_SOUND4CNT_HI = 0x07C,
  REG_SOUNDCNT_LO = 0x080,
  REG_SOUNDCNT_HI = 0x082,
  REG_SOUNDCNT_X = 0x084,
  REG_SOUNDBIAS = 0x088,
  REG_WAVE_RAM0_LO = 0x090,
  REG_WAVE_RAM3_HI = 0x09E,
  REG_FIFO_A_LO = 0x0A0,
  REG_FIFO_A_HI = 0x0A2,
  REG_FIFO_B_LO = 0x0A4,
  REG_FIFO_B_HI = 0x0A6,
  REG_DMA0SAD_LO = 0x0B0,
  REG_DMA3CNT_HI = 0x0DE,
  REG_TM0CNT_LO = 0x100,
  REG_TM3CNT_HI = 0x10E,
  REG_SIODATA32_LO = 0x120,
  REG_SIOCNT = 0x128,
  REG_KEYINPUT = 0x130,
  REG_KEYCNT = 0x132,
  REG_RCNT = 0x134,
  REG_JOYCNT = 0x140,
  REG_JOYSTAT = 0x158,
  REG_IE = 0x200,
  REG_IF = 0x202,
  REG_WAITCNT = 0x204,
  REG_IME = 0x208,
  REG_MAX = 0x20A,
  REG_INTERNAL_EXWAITCNT_LO = 0x210,
  REG_INTERNAL_EXWAITCNT_HI = 0x212,
  REG_POSTFLG = 0x300,
  REG_EXWAITCNT_LO = 0x800,
  REG_EXWAITCNT_HI = 0x802
};

/* The interrupts, by their bit in IE and IF. */
enum { IRQ_VBLANK, IRQ_HBLANK, IRQ_VCOUNTER, IRQ_TIMER0, IRQ_TIMER1, IRQ_TIMER2, IRQ_TIMER3, IRQ_SIO, IRQ_DMA0,
       IRQ_DMA1, IRQ_DMA2, IRQ_DMA3, IRQ_KEYPAD, IRQ_GAMEPAK };

/* --- the screen's timing: 228 lines of 1,232 cycles, the first 160 drawn --- */

#define HDRAW_CYCLES 1008
#define HBLANK_CYCLES 224
#define LINES_DRAWN 160
#define LINES_IN_FRAME 228

/* An interrupt reaches the processor this many cycles after it is raised. */
#define IRQ_DELAY 7

/* --- the events, and the order of those that land at the same moment (lower first) --- */

enum { EVENT_IRQ, EVENT_VIDEO, EVENT_AUDIO, EVENT_TIMER0, EVENT_TIMER1, EVENT_TIMER2, EVENT_TIMER3, EVENT_DMA, EVENT_COUNT };
static const unsigned EVENT_PRIORITY[EVENT_COUNT] = {0x00, 0x08, 0x18, 0x20, 0x21, 0x22, 0x23, 0x40};

typedef struct {
  int scheduled;
  uint64_t when;
} boot_event;

/* --- the processor's modes, and which registers each keeps of its own --- */

enum { MODE_USER = 0x10, MODE_FIQ = 0x11, MODE_IRQ = 0x12, MODE_SUPERVISOR = 0x13, MODE_ABORT = 0x17,
       MODE_UNDEFINED = 0x1B, MODE_SYSTEM = 0x1F };
enum { BANK_NONE, BANK_FIQ, BANK_IRQ, BANK_SUPERVISOR, BANK_ABORT, BANK_UNDEFINED, BANK_COUNT };

#define PSR_N 0x80000000u
#define PSR_Z 0x40000000u
#define PSR_C 0x20000000u
#define PSR_V 0x10000000u
#define PSR_I 0x00000080u
#define PSR_T 0x00000020u
#define PSR_MODE 0x0000001Fu
#define PSR_USER_MASK 0xF0000000u
#define PSR_PRIV_MASK 0x000000CFu
#define PSR_STATE_MASK 0x00000020u

#define REG_SP 13
#define REG_LR 14
#define REG_PC 15

/* --- the copy engines, the timers and the recorded-sound queues --- */

typedef struct {
  uint16_t reg; /* the control register as the engine holds it */
  uint32_t source, dest;
  int32_t count;      /* how many units a run moves */
  uint32_t next_source, next_dest;
  int32_t next_count; /* how many are left in the run under way; the top bit marks a run just finished */
  uint32_t when;      /* the moment its next unit moves, on the 32-bit clock mGBA counts these by */
} boot_dma;

#define DMA_DEST_CONTROL(reg) (((reg) >> 5) & 3u)
#define DMA_SRC_CONTROL(reg) (((reg) >> 7) & 3u)
#define DMA_REPEAT(reg) (((reg) >> 9) & 1u)
#define DMA_WIDTH(reg) (((reg) >> 10) & 1u)
#define DMA_TIMING(reg) (((reg) >> 12) & 3u)
#define DMA_DO_IRQ(reg) (((reg) >> 14) & 1u)
#define DMA_ENABLE(reg) (((reg) >> 15) & 1u)
enum { DMA_TIMING_NOW, DMA_TIMING_VBLANK, DMA_TIMING_HBLANK, DMA_TIMING_CUSTOM };
enum { DMA_INCREMENT, DMA_DECREMENT, DMA_FIXED, DMA_INCREMENT_RELOAD };

typedef struct {
  uint16_t reload;
  uint32_t last_event; /* on the 32-bit clock, as mGBA keeps it */
  unsigned prescale_bits;
  int count_up, do_irq, enable;
} boot_timer;

#define FIFO_WORDS 8
#define MOST_SAMPLES_A_TICK 16

typedef struct {
  uint32_t words[FIFO_WORDS];
  int write, read;
  uint32_t internal_sample;
  int internal_remaining;
  int dma_source;
  int8_t samples[MOST_SAMPLES_A_TICK];
} boot_fifo;

/* --- the picture's state, as mGBA's renderer keeps it (the renderer is further down) --- */

#define BG_ENABLED_MAX 4

typedef struct {
  int index;
  int enabled; /* 0 off; counts up to BG_ENABLED_MAX over the lines after it is switched on; -2 off mid-frame */
  unsigned priority;
  uint32_t char_base, screen_base;
  int mosaic, multipalette, overflow, size;
  int16_t dx, dmx, dy, dmy;
  int32_t refx, refy, sx, sy;
  int target1, target2;
  uint32_t flags, objwin_flags;
  int variant;
} boot_background;

typedef struct {
  uint8_t packed;
  int priority;
} boot_window_control;

typedef struct {
  struct {
    int start, end;
  } h, v;
  boot_window_control control;
} boot_window_n;

typedef struct {
  int end_x;
  boot_window_control control;
} boot_window;

#define MOST_WINDOWS 5

typedef struct {
  int y, end_y, cycles, index;
  uint16_t a, b, c;
} boot_sprite;

enum { BLEND_NONE, BLEND_ALPHA, BLEND_BRIGHTEN, BLEND_DARKEN };

struct rg_bios_boot {
  /* memories */
  uint8_t bios[SIZE_BIOS];
  uint8_t cartridge[RG_BIOS_BOOT_CARTRIDGE_BYTES];
  uint32_t rom_size;
  uint8_t ewram[SIZE_EWRAM];
  uint8_t iwram[SIZE_IWRAM];
  uint8_t palette[SIZE_PALETTE];
  uint8_t vram[SIZE_VRAM];
  uint8_t oam[SIZE_OAM];
  uint16_t io[SIZE_IO / 2];

  /* the processor */
  uint32_t r[16];
  uint32_t cpsr, spsr;
  int privilege_mode;
  uint32_t banked[BANK_COUNT][7];
  uint32_t banked_spsr[BANK_COUNT];
  int thumb;
  uint32_t prefetch[2];
  int halted;
  uint32_t shifter_operand;
  int shifter_carry;

  /* time: the processor's cycles since the last events were done, and the clock at that moment */
  int32_t cycles;
  int32_t next_event;
  uint64_t master;
  boot_event events[EVENT_COUNT];
  int early_exit;
  int cpu_blocked;

  /* the memory bus */
  int active_region; /* where the processor is fetching from, or -1 for nowhere it can */
  int active_seq32, active_seq16, active_nonseq32, active_nonseq16;
  int waits_nonseq16[16], waits_seq16[16], waits_nonseq32[16], waits_seq32[16];
  uint32_t bios_prefetch;
  uint32_t bus;
  uint32_t dma_pc;
  int performing_dma;
  int prefetch_enabled;

  /* the copy engines, the timers and the sound queues */
  boot_dma dma[4];
  int active_dma;
  uint32_t dma_transfer;
  boot_timer timers[4];
  boot_fifo fifo[2];

  /* the sound's mixer */
  int audio_enable;
  int volume, volume_a, volume_b;
  int a_left, a_right, a_timer, b_left, b_right, b_timer;
  uint16_t soundbias;
  int32_t sample_interval;
  uint32_t last_sample; /* on the 32-bit clock */
  int sample_index;
  int16_t current_samples[MOST_SAMPLES_A_TICK][2];
  int16_t frame_sound[2 * RG_BIOS_BOOT_SOUND_MOST];
  int frame_sound_count;
  int16_t sound_shown[2 * RG_BIOS_BOOT_SOUND_MOST];
  int sound_shown_count;

  /* the screen's timing */
  int vcount;
  int video_next_is_hdraw;
  int should_stall;
  long frame_counter;
  int reached_game;
  uint16_t keys_last;

  /* the link port */
  uint16_t sio_rcnt, sio_siocnt;
  int sio_mode;

  /* the picture */
  uint32_t output[RG_BIOS_BOOT_WIDTH * RG_BIOS_BOOT_HEIGHT];
  uint32_t shown[RG_BIOS_BOOT_WIDTH * RG_BIOS_BOOT_HEIGHT];
  uint16_t dispcnt;
  boot_background bg[4];
  int blend_effect;
  int target1_obj, target1_bd, target2_obj, target2_bd;
  int blda, bldb, bldy;
  int blend_dirty;
  uint32_t normal_palette[512], variant_palette[512];
  boot_window_n win_n[2];
  boot_window_control winout, objwin, current_window;
  boot_window windows[MOST_WINDOWS];
  int n_windows;
  int start, end;
  int next_y;
  int oam_dirty, oam_max;
  boot_sprite sprites[128];
  int sprite_cycles_remaining;
  int force_target1;
  uint16_t mosaic;
  uint32_t row[RG_BIOS_BOOT_WIDTH];
  uint32_t sprite_layer[RG_BIOS_BOOT_WIDTH];

  char unhandled[160];
};

/* --- small sums the processor does --- */

static inline uint32_t ror32(uint32_t value, unsigned rotate) {
  rotate &= 31u;
  return rotate ? (value >> rotate) | (value << (32u - rotate)) : value;
}

static inline uint32_t asr32(uint32_t value, unsigned shift) {
  if (shift >= 32u) return (value & 0x80000000u) ? 0xFFFFFFFFu : 0u;
  if (!shift) return value;
  uint32_t shifted = value >> shift;
  return (value & 0x80000000u) ? shifted | ~(0xFFFFFFFFu >> shift) : shifted;
}

static inline uint32_t sign_extend8(uint32_t value) { return (value & 0x80u) ? value | 0xFFFFFF00u : value & 0xFFu; }
static inline uint32_t sign_extend16(uint32_t value) { return (value & 0x8000u) ? value | 0xFFFF0000u : value & 0xFFFFu; }

static inline uint32_t load_le32(const uint8_t *p) {
  return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}
static inline uint16_t load_le16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }
static inline void store_le32(uint8_t *p, uint32_t value) {
  p[0] = (uint8_t)value;
  p[1] = (uint8_t)(value >> 8);
  p[2] = (uint8_t)(value >> 16);
  p[3] = (uint8_t)(value >> 24);
}
static inline void store_le16(uint8_t *p, uint16_t value) {
  p[0] = (uint8_t)value;
  p[1] = (uint8_t)(value >> 8);
}

static int popcount16(uint32_t mask) {
  int count = 0;
  for (; mask; mask &= mask - 1u) count++;
  return count;
}

/* Notes the first thing asked of the console that is not emulated here, for the tests. */
static void note_unhandled(rg_bios_boot *b, const char *what, uint32_t where) {
  if (b->unhandled[0]) return;
  snprintf(b->unhandled, sizeof b->unhandled, "%s at 0x%08X (instruction 0x%08X)", what, where,
           b->r[REG_PC] - (b->thumb ? 2u : 4u) * 2u);
}

/* ======================================================================================== */
/* TIME                                                                                     */
/* ======================================================================================== */

/* The clock now: during an instruction, the moment it began. */
static inline uint64_t now(const rg_bios_boot *b) { return b->master + (uint64_t)(int64_t)b->cycles; }
static inline uint32_t now32(const rg_bios_boot *b) { return (uint32_t)now(b); }

/* Puts +event+ +delay+ cycles from now (a negative delay is a moment already passed, which is done
 * at the next chance). */
static void schedule(rg_bios_boot *b, int event, int32_t delay) {
  int32_t relative = delay + b->cycles;
  b->events[event].when = (uint64_t)((int64_t)b->master + (int64_t)relative);
  b->events[event].scheduled = 1;
  if (relative < b->next_event) b->next_event = relative;
}

static void deschedule(rg_bios_boot *b, int event) { b->events[event].scheduled = 0; }

/* How many cycles from now until +event+ is due. */
static int32_t until_event(const rg_bios_boot *b, int event) { return (int32_t)(b->events[event].when - now(b)); }

static void run_event(rg_bios_boot *b, int event, uint32_t late);

/* The next event due, the earliest first and the lower priority first at the same moment, or -1. */
static int first_event(const rg_bios_boot *b) {
  int first = -1;
  for (int i = 0; i < EVENT_COUNT; i++) {
    if (!b->events[i].scheduled) continue;
    if (first < 0 || b->events[i].when < b->events[first].when ||
        (b->events[i].when == b->events[first].when && EVENT_PRIORITY[i] < EVENT_PRIORITY[first]))
      first = i;
  }
  return first;
}

/* Moves the clock on by +amount+ and does every event that is then due. Gives the cycles until the
 * next event. */
static int32_t tick(rg_bios_boot *b, int32_t amount) {
  b->master += (uint64_t)(int64_t)amount;
  for (;;) {
    int next = first_event(b);
    if (next < 0) return INT_MAX;
    int64_t until = (int64_t)(b->events[next].when - b->master);
    if (until > 0) return until > INT_MAX ? INT_MAX : (int32_t)until;
    b->events[next].scheduled = 0;
    run_event(b, next, (uint32_t)(-until));
  }
}

static void test_irq(rg_bios_boot *b, uint32_t late);

/* Everything that is due, done between two instructions; and while the processor is asleep, or
 * held while a copy runs, the clock goes on from one event to the next until it can run again. */
static void process_events(rg_bios_boot *b) {
  b->bus = b->prefetch[1];
  if (b->thumb) b->bus |= b->prefetch[1] << 16;

  int32_t next_event = b->next_event;
  while (b->cycles >= next_event) {
    b->next_event = INT_MAX;
    next_event = 0;
    do {
      int32_t cycles = b->cycles;
      b->cycles = 0;
      next_event = tick(b, cycles < next_event ? next_event : cycles);
    } while (b->cpu_blocked && !b->early_exit);
    b->next_event = next_event;
    if (b->halted) {
      b->cycles = next_event;
      if (!b->io[REG_IME >> 1] || !b->io[REG_IE >> 1]) break;
    }
    if (b->early_exit) break;
  }
  b->early_exit = 0;
  if (b->cpu_blocked) b->cycles = b->next_event;
}

/* ======================================================================================== */
/* THE PROCESSOR'S MODES AND STATUS                                                         */
/* ======================================================================================== */

static int bank_of(int mode) {
  switch (mode) {
  case MODE_FIQ: return BANK_FIQ;
  case MODE_IRQ: return BANK_IRQ;
  case MODE_SUPERVISOR: return BANK_SUPERVISOR;
  case MODE_ABORT: return BANK_ABORT;
  case MODE_UNDEFINED: return BANK_UNDEFINED;
  default: return BANK_NONE;
  }
}

static int mode_has_spsr(int mode) { return mode != MODE_SYSTEM && mode != MODE_USER; }

/* Moves to +mode+'s registers: each mode but user and system keeps its own stack pointer and return
 * address, and the fast-interrupt mode r8 to r12 too. */
static void set_privilege_mode(rg_bios_boot *b, int mode) {
  if (mode == b->privilege_mode) return;
  int new_bank = bank_of(mode), old_bank = bank_of(b->privilege_mode);
  if (new_bank != old_bank) {
    if (mode == MODE_FIQ || b->privilege_mode == MODE_FIQ) {
      int old_fiq = old_bank == BANK_FIQ, new_fiq = new_bank == BANK_FIQ;
      for (int i = 0; i < 5; i++) {
        b->banked[old_fiq][2 + i] = b->r[8 + i];
        b->r[8 + i] = b->banked[new_fiq][2 + i];
      }
    }
    b->banked[old_bank][0] = b->r[REG_SP];
    b->banked[old_bank][1] = b->r[REG_LR];
    b->r[REG_SP] = b->banked[new_bank][0];
    b->r[REG_LR] = b->banked[new_bank][1];
    b->banked_spsr[old_bank] = b->spsr;
    b->spsr = b->banked_spsr[new_bank];
  }
  b->privilege_mode = mode;
}

static void set_active_region(rg_bios_boot *b, uint32_t address);

/* Switches between ARM and THUMB, and asks for the events to be looked at before going on. */
static void set_instruction_set(rg_bios_boot *b, int thumb) {
  if (thumb == b->thumb) return;
  b->thumb = thumb;
  if (thumb) b->cpsr |= PSR_T;
  else b->cpsr &= ~PSR_T;
  b->next_event = b->cycles;
}

/* What the processor does once its status register has been written whole. */
static void read_cpsr(rg_bios_boot *b) {
  set_instruction_set(b, (b->cpsr & PSR_T) != 0);
  set_privilege_mode(b, (int)(b->cpsr & PSR_MODE));
  test_irq(b, 0);
}

/* ======================================================================================== */
/* THE MEMORY BUS                                                                           */
/* ======================================================================================== */

/* How many extra cycles a memory takes beyond the one every access takes, by region. */
static const int BASE_WAITS_NONSEQ16[16] = {0, 0, 2, 0, 0, 0, 0, 0, 4, 4, 4, 4, 4, 4, 4, 0};
static const int BASE_WAITS_NONSEQ32[16] = {0, 0, 5, 0, 0, 1, 1, 0, 7, 7, 9, 9, 13, 13, 9, 0};
static const int BASE_WAITS_SEQ16[16] = {0, 0, 2, 0, 0, 0, 0, 0, 2, 2, 4, 4, 8, 8, 4, 0};
static const int BASE_WAITS_SEQ32[16] = {0, 0, 5, 0, 0, 1, 1, 0, 5, 5, 9, 9, 17, 17, 9, 0};
static const int ROM_WAITS[4] = {4, 3, 2, 8};
static const int ROM_WAITS_SEQ[6] = {2, 1, 4, 1, 8, 1};

static void refresh_active_waits(rg_bios_boot *b) {
  if (b->active_region < 0) return;
  b->active_seq32 = b->waits_seq32[b->active_region];
  b->active_seq16 = b->waits_seq16[b->active_region];
  b->active_nonseq32 = b->waits_nonseq32[b->active_region];
  b->active_nonseq16 = b->waits_nonseq16[b->active_region];
}

/* WAITCNT: how long the cartridge's memories take. */
static void adjust_waitstates(rg_bios_boot *b, uint16_t parameters) {
  int sram = parameters & 3, ws0 = (parameters >> 2) & 3, ws0seq = (parameters >> 4) & 1, ws1 = (parameters >> 5) & 3,
      ws1seq = (parameters >> 7) & 1, ws2 = (parameters >> 8) & 3, ws2seq = (parameters >> 10) & 1;
  for (int region = REGION_CART_SRAM; region <= REGION_CART_SRAM_MIRROR; region++) {
    b->waits_nonseq16[region] = b->waits_seq16[region] = ROM_WAITS[sram];
    b->waits_nonseq32[region] = b->waits_seq32[region] = 2 * ROM_WAITS[sram] + 1;
  }
  const int nonseq[3] = {ROM_WAITS[ws0], ROM_WAITS[ws1], ROM_WAITS[ws2]};
  const int seq[3] = {ROM_WAITS_SEQ[ws0seq], ROM_WAITS_SEQ[ws1seq + 2], ROM_WAITS_SEQ[ws2seq + 4]};
  for (int i = 0; i < 3; i++) {
    for (int region = REGION_CART0 + 2 * i; region <= REGION_CART0 + 2 * i + 1; region++) {
      b->waits_nonseq16[region] = nonseq[i];
      b->waits_seq16[region] = seq[i];
      b->waits_nonseq32[region] = nonseq[i] + 1 + seq[i];
      b->waits_seq32[region] = 2 * seq[i] + 1;
    }
  }
  b->prefetch_enabled = (parameters & 0x4000) != 0;
  refresh_active_waits(b);
}

/* The work memory's own timing register, at 0x04000800. */
static void adjust_ewram_waitstates(rg_bios_boot *b, uint16_t parameters) {
  int wait = 15 - ((parameters >> 8) & 0xF);
  if (!wait) {
    note_unhandled(b, "work memory set to no wait", 0x04000800u);
    return;
  }
  b->waits_nonseq16[REGION_EWRAM] = b->waits_seq16[REGION_EWRAM] = wait;
  b->waits_nonseq32[REGION_EWRAM] = b->waits_seq32[REGION_EWRAM] = 2 * wait + 1;
  refresh_active_waits(b);
}

/* What a read from nowhere gives: what the bus last held, which is mostly the instruction after the
 * next one, or the last word a copy moved. */
static uint32_t load_bad(rg_bios_boot *b) {
  uint32_t width = b->thumb ? 2u : 4u;
  if (b->performing_dma || b->r[REG_PC] - b->dma_pc == width) return b->bus;
  uint32_t value = b->prefetch[1];
  if (b->thumb) {
    switch (b->r[REG_PC] >> 24) {
    case REGION_BIOS:
    case REGION_OAM: value = (value << 16) | b->prefetch[0]; break;
    case REGION_IWRAM:
      if (b->r[REG_PC] & 2u) value = (value << 16) | b->prefetch[0];
      else value |= b->prefetch[0] << 16;
      break;
    default: value |= value << 16;
    }
  }
  return value;
}

/* Where the processor fetches its instructions from, the region and its timing; leaving the BIOS
 * keeps the last thing it fetched there, which is what a read of the BIOS from outside it gives. */
static void set_active_region(rg_bios_boot *b, uint32_t address) {
  int new_region = (int)(address >> 24);
  if (new_region == b->active_region) {
    if (new_region < REGION_CART0 || (address & (SIZE_CART0 - 1u)) < b->rom_size) return;
  }
  if (b->active_region == REGION_BIOS) b->bios_prefetch = b->prefetch[1];
  b->active_region = new_region;
  switch (new_region) {
  case REGION_BIOS:
  case REGION_EWRAM:
  case REGION_IWRAM:
  case REGION_PALETTE:
  case REGION_VRAM:
  case REGION_OAM: break;
  case REGION_CART0:
  case REGION_CART0 + 1:
  case REGION_CART0 + 2:
  case REGION_CART0 + 3:
  case REGION_CART0 + 4:
  case REGION_CART0 + 5:
    if ((address & (SIZE_CART0 - 1u)) < b->rom_size) break;
    /* fall through */
  default:
    b->active_region = -1;
    note_unhandled(b, "jump to where there is no code", address);
    return;
  }
  refresh_active_waits(b);
}

/* The instruction-sized word at +address+ of the region the processor runs from, read the way the
 * fetch reads it: no side effects, and the region's own mirroring. */
static uint32_t fetch(const rg_bios_boot *b, uint32_t address, int width) {
  const uint8_t *base;
  uint32_t mask;
  switch (b->active_region) {
  case REGION_BIOS: base = b->bios; mask = SIZE_BIOS - 1u; break;
  case REGION_EWRAM: base = b->ewram; mask = SIZE_EWRAM - 1u; break;
  case REGION_IWRAM: base = b->iwram; mask = SIZE_IWRAM - 1u; break;
  case REGION_PALETTE: base = b->palette; mask = SIZE_PALETTE - 1u; break;
  case REGION_VRAM:
    if (address & 0x10000u) {
      base = b->vram + 0x10000;
      mask = 0x7FFFu;
    } else {
      base = b->vram;
      mask = 0xFFFFu;
    }
    break;
  case REGION_OAM: base = b->oam; mask = SIZE_OAM - 1u; break;
  case REGION_CART0:
  case REGION_CART0 + 1:
  case REGION_CART0 + 2:
  case REGION_CART0 + 3:
  case REGION_CART0 + 4:
  case REGION_CART0 + 5: {
    uint32_t at = address & (SIZE_CART0 - 1u) & ~(uint32_t)(width - 1);
    if (at + (uint32_t)width > RG_BIOS_BOOT_CARTRIDGE_BYTES) return 0;
    return width == 4 ? load_le32(b->cartridge + at) : load_le16(b->cartridge + at);
  }
  default: return width == 4 ? 0xDEADBEEFu : 0xBEEFu;
  }
  uint32_t at = address & mask & ~(uint32_t)(width - 1);
  return width == 4 ? load_le32(base + at) : load_le16(base + at);
}

/* The processor jumped: the next two instructions are fetched afresh from where it went, and the
 * jump costs a fetch that is not in order and one that is. */
static int32_t arm_write_pc(rg_bios_boot *b) {
  uint32_t pc = b->r[REG_PC] & ~1u;
  set_active_region(b, pc);
  b->prefetch[0] = fetch(b, pc, 4);
  pc += 4;
  b->prefetch[1] = fetch(b, pc, 4);
  b->r[REG_PC] = pc;
  return 2 + b->active_nonseq32 + b->active_seq32;
}

static int32_t thumb_write_pc(rg_bios_boot *b) {
  uint32_t pc = b->r[REG_PC] & ~1u;
  set_active_region(b, pc);
  b->prefetch[0] = fetch(b, pc, 2);
  pc += 2;
  b->prefetch[1] = fetch(b, pc, 2);
  b->r[REG_PC] = pc;
  return 2 + b->active_nonseq16 + b->active_seq16;
}

static int32_t write_pc(rg_bios_boot *b) { return b->thumb ? thumb_write_pc(b) : arm_write_pc(b); }

/* While a line is being drawn on a turning screen with both backgrounds up, the display has the
 * picture's memory to itself, and the processor waits until the line is drawn to reach it. */
static int32_t vram_stall(const rg_bios_boot *b, int32_t wait) {
  uint16_t dispcnt = b->io[REG_DISPCNT >> 1];
  if ((dispcnt & 7u) != 2 || !(dispcnt & 0x0400u) || !(dispcnt & 0x0800u)) return 0;
  int32_t stall = until_event(b, EVENT_VIDEO) - wait;
  return stall < 0 ? 0 : stall;
}

static uint16_t io_read(rg_bios_boot *b, uint32_t address);
static void io_write16(rg_bios_boot *b, uint32_t address, uint16_t value);
static void io_write8(rg_bios_boot *b, uint32_t address, uint8_t value);
static void io_write32(rg_bios_boot *b, uint32_t address, uint32_t value);
static void renderer_write_oam(rg_bios_boot *b);
static void renderer_write_palette(rg_bios_boot *b, uint32_t address, uint16_t value);

/* Whether the +width+ bytes of the cartridge at +at+ are among those the emulator was given. Past
 * the end of the game there is nothing, and a read there gives what mGBA gives for a cartridge with
 * nothing there; the start-up reads such a place once. Anywhere else, the game's own bytes are
 * there, and this was not given them. */
static int cart_known(rg_bios_boot *b, uint32_t at, uint32_t width, uint32_t address) {
  if (at + width <= RG_BIOS_BOOT_CARTRIDGE_BYTES) return 1;
  if (at < b->rom_size) note_unhandled(b, "read of the cartridge past the bytes given", address);
  return 0;
}

static uint32_t load_cart32(rg_bios_boot *b, uint32_t address) {
  uint32_t at = address & (SIZE_CART0 - 4u);
  if (cart_known(b, at, 4, address)) return load_le32(b->cartridge + at);
  return (((address & ~3u) >> 1) & 0xFFFFu) | ((((address & ~3u) + 2u) >> 1) << 16);
}

static uint32_t mode_is_bitmap(const rg_bios_boot *b) { return (b->io[REG_DISPCNT >> 1] & 7u) >= 3; }

/* The picture's memory is 96K, seen as 128K: the last 32K repeats the 32K before it. */
static uint32_t vram_offset(uint32_t address) {
  uint32_t at = address & 0x1FFFFu;
  return at >= SIZE_VRAM ? address & 0x17FFFu : at;
}

static uint32_t load32(rg_bios_boot *b, uint32_t address, int32_t *cycles) {
  uint32_t value = 0;
  int32_t wait = 0;
  switch (address >> 24) {
  case REGION_BIOS:
    if (address < SIZE_BIOS) {
      if (b->active_region == REGION_BIOS) value = load_le32(b->bios + (address & ~3u));
      else value = b->bios_prefetch;
    } else {
      value = load_bad(b);
    }
    break;
  case REGION_EWRAM:
    value = load_le32(b->ewram + (address & (SIZE_EWRAM - 4u)));
    wait += b->waits_nonseq32[REGION_EWRAM];
    break;
  case REGION_IWRAM: value = load_le32(b->iwram + (address & (SIZE_IWRAM - 4u))); break;
  case REGION_IO:
    value = io_read(b, address & 0xFFFFFFu & ~3u) | (uint32_t)io_read(b, (address & 0xFFFFFFu & ~1u) | 2u) << 16;
    break;
  case REGION_PALETTE:
    value = load_le32(b->palette + (address & (SIZE_PALETTE - 4u)));
    wait += b->waits_nonseq32[REGION_PALETTE];
    break;
  case REGION_VRAM:
    if ((address & 0x1FFFFu) >= SIZE_VRAM && (address & (SIZE_VRAM | 0x14000u)) == SIZE_VRAM && mode_is_bitmap(b))
      value = 0;
    else value = load_le32(b->vram + (vram_offset(address) & ~3u));
    ++wait;
    if (b->should_stall && (address & 0x1FFFFu) < (mode_is_bitmap(b) ? 0x14000u : 0x10000u)) wait += vram_stall(b, wait);
    break;
  case REGION_OAM: value = load_le32(b->oam + (address & (SIZE_OAM - 4u))); break;
  case REGION_CART0:
  case REGION_CART0 + 1:
  case REGION_CART0 + 2:
  case REGION_CART0 + 3:
  case REGION_CART0 + 4:
  case REGION_CART0 + 5:
    wait += b->waits_nonseq32[address >> 24];
    value = load_cart32(b, address);
    break;
  case REGION_CART_SRAM:
  case REGION_CART_SRAM_MIRROR:
    note_unhandled(b, "read of save memory", address);
    wait = b->waits_nonseq16[address >> 24];
    value = 0xFFFFFFFFu;
    break;
  default: value = load_bad(b); break;
  }
  if (cycles) *cycles += wait + 2;
  return ror32(value, (address & 3u) << 3);
}

static uint32_t load16(rg_bios_boot *b, uint32_t address, int32_t *cycles) {
  uint32_t value = 0;
  int32_t wait = 0;
  switch (address >> 24) {
  case REGION_BIOS:
    if (address < SIZE_BIOS) {
      if (b->active_region == REGION_BIOS) value = load_le16(b->bios + (address & ~1u));
      else value = (b->bios_prefetch >> ((address & 2u) * 8u)) & 0xFFFFu;
    } else {
      value = (load_bad(b) >> ((address & 2u) * 8u)) & 0xFFFFu;
    }
    break;
  case REGION_EWRAM:
    value = load_le16(b->ewram + (address & (SIZE_EWRAM - 2u)));
    wait = b->waits_nonseq16[REGION_EWRAM];
    break;
  case REGION_IWRAM: value = load_le16(b->iwram + (address & (SIZE_IWRAM - 2u))); break;
  case REGION_IO: value = io_read(b, address & (0xFFFFFFu - 1u)); break;
  case REGION_PALETTE: value = load_le16(b->palette + (address & (SIZE_PALETTE - 2u))); break;
  case REGION_VRAM:
    if ((address & 0x1FFFFu) >= SIZE_VRAM && (address & (SIZE_VRAM | 0x14000u)) == SIZE_VRAM && mode_is_bitmap(b)) {
      value = 0;
      break;
    }
    value = load_le16(b->vram + (vram_offset(address) & ~1u));
    if (b->should_stall && (address & 0x1FFFFu) < (mode_is_bitmap(b) ? 0x14000u : 0x10000u)) wait += vram_stall(b, wait);
    break;
  case REGION_OAM: value = load_le16(b->oam + (address & (SIZE_OAM - 2u))); break;
  case REGION_CART0:
  case REGION_CART0 + 1:
  case REGION_CART0 + 2:
  case REGION_CART0 + 3:
  case REGION_CART0 + 4:
  case REGION_CART0 + 5: {
    wait = b->waits_nonseq16[address >> 24];
    uint32_t at = address & (SIZE_CART0 - 2u);
    value = cart_known(b, at, 2, address) ? load_le16(b->cartridge + at) : (address >> 1) & 0xFFFFu;
    break;
  }
  case REGION_CART_SRAM:
  case REGION_CART_SRAM_MIRROR:
    note_unhandled(b, "read of save memory", address);
    wait = b->waits_nonseq16[address >> 24];
    value = 0xFFFFu;
    break;
  default: value = (load_bad(b) >> ((address & 2u) * 8u)) & 0xFFFFu; break;
  }
  if (cycles) *cycles += wait + 2;
  return ror32(value, (address & 1u) << 3);
}

static uint32_t load8(rg_bios_boot *b, uint32_t address, int32_t *cycles) {
  uint32_t value = 0;
  int32_t wait = 0;
  switch (address >> 24) {
  case REGION_BIOS:
    if (address < SIZE_BIOS) {
      if (b->active_region == REGION_BIOS) value = b->bios[address];
      else value = (b->bios_prefetch >> ((address & 3u) * 8u)) & 0xFFu;
    } else {
      value = (load_bad(b) >> ((address & 3u) * 8u)) & 0xFFu;
    }
    break;
  case REGION_EWRAM:
    value = b->ewram[address & (SIZE_EWRAM - 1u)];
    wait = b->waits_nonseq16[REGION_EWRAM];
    break;
  case REGION_IWRAM: value = b->iwram[address & (SIZE_IWRAM - 1u)]; break;
  case REGION_IO: value = ((uint32_t)io_read(b, address & 0xFFFEu) >> ((address & 1u) << 3)) & 0xFFu; break;
  case REGION_PALETTE: value = b->palette[address & (SIZE_PALETTE - 1u)]; break;
  case REGION_VRAM:
    if ((address & 0x1FFFFu) >= SIZE_VRAM && (address & (SIZE_VRAM | 0x14000u)) == SIZE_VRAM && mode_is_bitmap(b)) {
      value = 0;
      break;
    }
    value = b->vram[vram_offset(address)];
    if (b->should_stall) wait += vram_stall(b, wait);
    break;
  case REGION_OAM: value = b->oam[address & (SIZE_OAM - 1u)]; break;
  case REGION_CART0:
  case REGION_CART0 + 1:
  case REGION_CART0 + 2:
  case REGION_CART0 + 3:
  case REGION_CART0 + 4:
  case REGION_CART0 + 5: {
    wait = b->waits_nonseq16[address >> 24];
    uint32_t at = address & (SIZE_CART0 - 1u);
    value = cart_known(b, at, 1, address) ? b->cartridge[at] : ((address >> 1) >> ((address & 1u) * 8u)) & 0xFFu;
    break;
  }
  case REGION_CART_SRAM:
  case REGION_CART_SRAM_MIRROR:
    note_unhandled(b, "read of save memory", address);
    wait = b->waits_nonseq16[address >> 24];
    value = 0xFFu;
    break;
  default: value = (load_bad(b) >> ((address & 3u) * 8u)) & 0xFFu; break;
  }
  if (cycles) *cycles += wait + 2;
  return value;
}

static void store32(rg_bios_boot *b, uint32_t address, uint32_t value, int32_t *cycles) {
  int32_t wait = 0;
  switch (address >> 24) {
  case REGION_EWRAM:
    store_le32(b->ewram + (address & (SIZE_EWRAM - 4u)), value);
    wait += b->waits_nonseq32[REGION_EWRAM];
    break;
  case REGION_IWRAM: store_le32(b->iwram + (address & (SIZE_IWRAM - 4u)), value); break;
  case REGION_IO: io_write32(b, address & (0xFFFFFFu - 3u), value); break;
  case REGION_PALETTE: {
    uint32_t at = address & (SIZE_PALETTE - 4u);
    if (load_le32(b->palette + at) != value) {
      store_le32(b->palette + at, value);
      renderer_write_palette(b, at + 2u, (uint16_t)(value >> 16));
      renderer_write_palette(b, at, (uint16_t)value);
    }
    wait += b->waits_nonseq32[REGION_PALETTE];
    break;
  }
  case REGION_VRAM:
    if ((address & 0x1FFFFu) >= SIZE_VRAM && (address & (SIZE_VRAM | 0x14000u)) == SIZE_VRAM && mode_is_bitmap(b)) {
      /* the bitmap modes have no memory there */
    } else {
      store_le32(b->vram + (vram_offset(address) & ~3u), value);
    }
    ++wait;
    if (b->should_stall && (address & 0x1FFFFu) < (mode_is_bitmap(b) ? 0x14000u : 0x10000u)) wait += vram_stall(b, wait);
    break;
  case REGION_OAM: {
    uint32_t at = address & (SIZE_OAM - 4u);
    if (load_le32(b->oam + at) != value) {
      store_le32(b->oam + at, value);
      renderer_write_oam(b);
    }
    break;
  }
  case REGION_CART0:
  case REGION_CART0 + 1:
  case REGION_CART0 + 2:
  case REGION_CART0 + 3:
  case REGION_CART0 + 4:
  case REGION_CART0 + 5:
    wait += b->waits_nonseq32[address >> 24];
    note_unhandled(b, "write to the cartridge", address);
    break;
  case REGION_CART_SRAM:
  case REGION_CART_SRAM_MIRROR: note_unhandled(b, "write to save memory", address); break;
  default: break;
  }
  if (cycles) *cycles += wait + 1;
}

static void store16(rg_bios_boot *b, uint32_t address, uint16_t value, int32_t *cycles) {
  int32_t wait = 0;
  switch (address >> 24) {
  case REGION_EWRAM:
    store_le16(b->ewram + (address & (SIZE_EWRAM - 2u)), value);
    wait = b->waits_nonseq16[REGION_EWRAM];
    break;
  case REGION_IWRAM: store_le16(b->iwram + (address & (SIZE_IWRAM - 2u)), value); break;
  case REGION_IO: io_write16(b, address & (0xFFFFFFu - 1u), value); break;
  case REGION_PALETTE: {
    uint32_t at = address & (SIZE_PALETTE - 2u);
    if (load_le16(b->palette + at) != value) {
      store_le16(b->palette + at, value);
      renderer_write_palette(b, at, value);
    }
    break;
  }
  case REGION_VRAM:
    if ((address & 0x1FFFFu) >= SIZE_VRAM && (address & (SIZE_VRAM | 0x14000u)) == SIZE_VRAM && mode_is_bitmap(b)) break;
    store_le16(b->vram + (vram_offset(address) & ~1u), value);
    if (b->should_stall && (address & 0x1FFFFu) < (mode_is_bitmap(b) ? 0x14000u : 0x10000u)) wait += vram_stall(b, wait);
    break;
  case REGION_OAM: {
    uint32_t at = address & (SIZE_OAM - 2u);
    if (load_le16(b->oam + at) != value) {
      store_le16(b->oam + at, value);
      renderer_write_oam(b);
    }
    break;
  }
  case REGION_CART0:
  case REGION_CART0 + 1:
  case REGION_CART0 + 2:
  case REGION_CART0 + 3:
  case REGION_CART0 + 4:
  case REGION_CART0 + 5: note_unhandled(b, "write to the cartridge", address); break;
  case REGION_CART_SRAM:
  case REGION_CART_SRAM_MIRROR: note_unhandled(b, "write to save memory", address); break;
  default: break;
  }
  if (cycles) *cycles += wait + 1;
}

static void store8(rg_bios_boot *b, uint32_t address, uint8_t value, int32_t *cycles) {
  int32_t wait = 0;
  switch (address >> 24) {
  case REGION_EWRAM:
    b->ewram[address & (SIZE_EWRAM - 1u)] = value;
    wait = b->waits_nonseq16[REGION_EWRAM];
    break;
  case REGION_IWRAM: b->iwram[address & (SIZE_IWRAM - 1u)] = value; break;
  case REGION_IO: io_write8(b, address & 0xFFFFFFu, value); break;
  case REGION_PALETTE:
    /* A byte written to the colours is written to both halves of its colour. */
    store16(b, address & ~1u, (uint16_t)(value | value << 8), cycles);
    break;
  case REGION_VRAM:
    /* ...and to both bytes of the picture's memory, except where sprites keep their tiles, which
     * a byte cannot be written to at all. */
    if ((address & 0x1FFFFu) >= (mode_is_bitmap(b) ? 0x14000u : 0x10000u)) break;
    store_le16(b->vram + (address & 0x1FFFEu), (uint16_t)(value | value << 8));
    if (b->should_stall) wait += vram_stall(b, wait);
    break;
  case REGION_OAM: break; /* the sprite table cannot be written a byte at a time */
  case REGION_CART_SRAM:
  case REGION_CART_SRAM_MIRROR: note_unhandled(b, "write to save memory", address); break;
  default: break;
  }
  if (cycles) *cycles += wait + 1;
}

/* LDM: the registers in +mask+ loaded from consecutive words, the first at +address+ as +direction+
 * sets (bit 0 decrementing, bit 1 before). Gives the address after the last. */
enum { LSM_B = 1, LSM_D = 2 };

/* What one word of a block transfer adds to +wait+: the region's in-order time. */
static int32_t block_word_wait(rg_bios_boot *b, int region, uint32_t address, int32_t wait) {
  switch (region) {
  case REGION_EWRAM:
  case REGION_PALETTE: return wait + b->waits_seq32[region];
  case REGION_VRAM:
    ++wait;
    if (b->should_stall && (address & 0x1FFFFu) < (mode_is_bitmap(b) ? 0x14000u : 0x10000u)) wait += vram_stall(b, wait);
    return wait;
  case REGION_CART0:
  case REGION_CART0 + 1:
  case REGION_CART0 + 2:
  case REGION_CART0 + 3:
  case REGION_CART0 + 4:
  case REGION_CART0 + 5: return wait + b->waits_seq32[region];
  default: return wait;
  }
}

static uint32_t load_multiple(rg_bios_boot *b, uint32_t address, uint32_t mask, int direction, int32_t *cycles) {
  uint32_t offset = 4;
  uint32_t count = 0;
  if (direction & LSM_D) {
    offset = (uint32_t)-4;
    count = (uint32_t)popcount16(mask);
    address -= (count << 2) - 4u;
  }
  if (direction & LSM_B) address += offset;
  uint32_t misalign = address & 3u;
  int region = (int)(address >> 24);
  if (region < REGION_CART_SRAM) address &= ~3u;
  /* The first word is out of order and the rest in order: the in-order time counted for every word,
   * and the difference for the first here. */
  int32_t wait = b->waits_seq32[region & 15] - b->waits_nonseq32[region & 15];
  if (!mask) {
    b->r[REG_PC] = load32(b, address, NULL);
    wait = block_word_wait(b, region, address, wait) + 16;
    address += 64;
  }
  for (int i = 0; i < 16; i++) {
    if (!(mask & (1u << i))) continue;
    uint32_t value = load32(b, address, NULL);
    wait = block_word_wait(b, region, address, wait);
    b->r[i] = value;
    ++wait;
    address += 4;
  }
  if (cycles) *cycles += wait + 1;
  if (direction & LSM_B) address -= offset;
  if (direction & LSM_D) address -= (count << 2) + 4u;
  return address | misalign;
}

static uint32_t store_multiple(rg_bios_boot *b, uint32_t address, uint32_t mask, int direction, int32_t *cycles) {
  uint32_t offset = 4;
  uint32_t count = 0;
  if (direction & LSM_D) {
    offset = (uint32_t)-4;
    count = (uint32_t)popcount16(mask);
    address -= (count << 2) - 4u;
  }
  if (direction & LSM_B) address += offset;
  uint32_t misalign = address & 3u;
  int region = (int)(address >> 24);
  if (region < REGION_CART_SRAM) address &= ~3u;
  int32_t wait = b->waits_seq32[region & 15] - b->waits_nonseq32[region & 15];
  if (!mask) {
    store32(b, address, b->r[REG_PC] + (b->thumb ? 2u : 4u), NULL);
    wait = block_word_wait(b, region, address, wait) + 16;
    address += 64;
  }
  for (int i = 0; i < 16; i++) {
    if (!(mask & (1u << i))) continue;
    uint32_t value = b->r[i];
    if (i == REG_PC) value += 4u;
    store32(b, address, value, NULL);
    wait = block_word_wait(b, region, address, wait);
    ++wait;
    address += 4;
  }
  if (cycles) *cycles += wait;
  if (direction & LSM_B) address -= offset;
  if (direction & LSM_D) address -= (count << 2) + 4u;
  return address | misalign;
}

/* ======================================================================================== */
/* INTERRUPTS                                                                               */
/* ======================================================================================== */

static void raise_irq(rg_bios_boot *b, int irq, uint32_t late) {
  b->io[REG_IF >> 1] |= (uint16_t)(1u << irq);
  test_irq(b, late);
}

/* An interrupt enabled and raised reaches the processor IRQ_DELAY cycles later. */
static void test_irq(rg_bios_boot *b, uint32_t late) {
  if (b->io[REG_IE >> 1] & b->io[REG_IF >> 1]) {
    if (!b->events[EVENT_IRQ].scheduled) schedule(b, EVENT_IRQ, IRQ_DELAY - (int32_t)late);
  }
}

/* The processor takes the interrupt: it saves where it was and its status, and runs the BIOS's
 * handler at 0x18 in ARM, with interrupts off. */
static void arm_raise_irq(rg_bios_boot *b) {
  if (b->cpsr & PSR_I) return;
  uint32_t cpsr = b->cpsr;
  uint32_t width = b->thumb ? 2u : 4u;
  set_privilege_mode(b, MODE_IRQ);
  b->cpsr = (b->cpsr & ~PSR_MODE) | MODE_IRQ;
  b->r[REG_LR] = b->r[REG_PC] - width + 4u;
  b->r[REG_PC] = 0x18;
  set_instruction_set(b, 0);
  b->cycles += arm_write_pc(b);
  b->spsr = cpsr;
  b->cpsr |= PSR_I;
  b->halted = 0;
}

/* SWI: the BIOS's own routines, run as its code at 0x08 in supervisor mode. */
static void arm_raise_swi(rg_bios_boot *b) {
  uint32_t cpsr = b->cpsr;
  uint32_t width = b->thumb ? 2u : 4u;
  set_privilege_mode(b, MODE_SUPERVISOR);
  b->cpsr = (b->cpsr & ~PSR_MODE) | MODE_SUPERVISOR;
  b->r[REG_LR] = b->r[REG_PC] - width;
  b->r[REG_PC] = 0x08;
  set_instruction_set(b, 0);
  b->cycles += arm_write_pc(b);
  b->spsr = cpsr;
  b->cpsr |= PSR_I;
}

static void arm_raise_undefined(rg_bios_boot *b) {
  uint32_t cpsr = b->cpsr;
  uint32_t width = b->thumb ? 2u : 4u;
  note_unhandled(b, "undefined instruction", b->r[REG_PC] - width * 2u);
  set_privilege_mode(b, MODE_UNDEFINED);
  b->cpsr = (b->cpsr & ~PSR_MODE) | MODE_UNDEFINED;
  b->r[REG_LR] = b->r[REG_PC] - width;
  b->r[REG_PC] = 0x04;
  set_instruction_set(b, 0);
  b->cycles += arm_write_pc(b);
  b->spsr = cpsr;
  b->cpsr |= PSR_I;
}

static void on_irq_event(rg_bios_boot *b) {
  b->halted = 0;
  if (!(b->io[REG_IE >> 1] & b->io[REG_IF >> 1])) return;
  if (b->io[REG_IME >> 1] && !(b->cpsr & PSR_I)) arm_raise_irq(b);
}

/* The processor asleep until an interrupt (HALTCNT). */
static void halt(rg_bios_boot *b) {
  b->next_event = b->cycles;
  b->halted = 1;
}

/* ======================================================================================== */
/* THE COPY ENGINES (DMA)                                                                   */
/* ======================================================================================== */

static const int32_t DMA_OFFSET[4] = {1, -1, 0, 1};

static void dma_update(rg_bios_boot *b);
static void audio_schedule_fifo_dma(rg_bios_boot *b, int number, boot_dma *info);

static uint32_t dma_write_source(rg_bios_boot *b, int dma, uint32_t address) {
  int valid = address >= 0x02000000u && !(dma == 0 && address >= 0x08000000u && address < 0x0E000000u);
  b->dma[dma].source = valid ? address & 0x0FFFFFFEu : 0;
  return b->dma[dma].source;
}

static uint32_t dma_write_dest(rg_bios_boot *b, int dma, uint32_t address) {
  address &= 0x0FFFFFFEu;
  if (dma == 3 || address < 0x08000000u) b->dma[dma].dest = address;
  return b->dma[dma].dest;
}

static void dma_write_count(rg_bios_boot *b, int dma, uint16_t count) {
  b->dma[dma].count = count ? count : (dma == 3 ? 0x10000 : 0x4000);
}

static void dma_schedule(rg_bios_boot *b, int number, boot_dma *info) {
  switch (DMA_TIMING(info->reg)) {
  case DMA_TIMING_NOW:
    info->when = now32(b) + 3u; /* a copy takes three cycles to start */
    info->next_count = info->count;
    break;
  case DMA_TIMING_HBLANK:
  case DMA_TIMING_VBLANK: return;
  case DMA_TIMING_CUSTOM:
    switch (number) {
    case 0: return;
    case 1:
    case 2: audio_schedule_fifo_dma(b, number, info); break;
    case 3: note_unhandled(b, "a copy started by the screen's lines (DMA3 special timing)", 0x040000DEu); break;
    }
  }
  dma_update(b);
}

static uint16_t dma_write_control(rg_bios_boot *b, int dma, uint16_t control) {
  boot_dma *current = &b->dma[dma];
  int was_enabled = (int)DMA_ENABLE(current->reg);
  control &= dma < 3 ? 0xF7E0u : 0xFFE0u;
  current->reg = control;
  if (!was_enabled && DMA_ENABLE(current->reg)) {
    current->next_source = current->source;
    current->next_dest = current->dest;
    uint32_t width = 2u << DMA_WIDTH(current->reg);
    current->next_source &= ~(width - 1u);
    current->next_dest &= ~(width - 1u);
    dma_schedule(b, dma, current);
  }
  return current->reg;
}

static void dma_run_on(rg_bios_boot *b, unsigned timing, int32_t cycles) {
  int found = 0;
  for (int i = 0; i < 4; i++) {
    boot_dma *dma = &b->dma[i];
    if (DMA_ENABLE(dma->reg) && DMA_TIMING(dma->reg) == timing && !dma->next_count) {
      dma->when = now32(b) + 3u + (uint32_t)cycles;
      dma->next_count = dma->count;
      found = 1;
    }
  }
  if (found) dma_update(b);
}

/* Which copy runs next: the one due soonest. */
static void dma_update(rg_bios_boot *b) {
  uint32_t current_time = now32(b);
  int32_t least_time = INT_MAX;
  b->active_dma = -1;
  for (int i = 0; i < 4; i++) {
    boot_dma *dma = &b->dma[i];
    if (DMA_ENABLE(dma->reg) && dma->next_count) {
      int32_t time = (int32_t)(dma->when - current_time);
      if (b->active_dma == -1 || time < least_time) {
        least_time = time;
        b->active_dma = i;
      }
    }
  }
  if (b->active_dma >= 0) {
    b->dma_pc = b->r[REG_PC];
    deschedule(b, EVENT_DMA);
    schedule(b, EVENT_DMA, (int32_t)(b->dma[b->active_dma].when - current_time));
  } else {
    b->cpu_blocked = 0;
  }
}

/* One unit of the copy under way, while the processor waits. */
static void dma_service(rg_bios_boot *b, int number, boot_dma *info) {
  uint32_t width = 2u << DMA_WIDTH(info->reg);
  int32_t remaining = info->next_count;
  uint32_t source = info->next_source, dest = info->next_dest;
  int source_region = (int)((source >> 24) & 15u), dest_region = (int)((dest >> 24) & 15u);
  int32_t cycles = 2;
  b->cpu_blocked = 1;
  if (info->count == info->next_count) {
    cycles += width == 4 ? b->waits_nonseq32[source_region] + b->waits_nonseq32[dest_region]
                         : b->waits_nonseq16[source_region] + b->waits_nonseq16[dest_region];
  } else {
    cycles += width == 4 ? b->waits_seq32[source_region] + b->waits_seq32[dest_region]
                         : b->waits_seq16[source_region] + b->waits_seq16[dest_region];
  }
  info->when += (uint32_t)cycles;

  b->performing_dma = 1 | (number << 1);
  if (width == 4) {
    if (source) b->dma_transfer = load32(b, source, NULL);
    b->bus = b->dma_transfer;
    store32(b, dest, b->dma_transfer, NULL);
  } else {
    if (source) {
      b->dma_transfer = load16(b, source, NULL);
      b->dma_transfer |= b->dma_transfer << 16;
    }
    store16(b, dest, (uint16_t)b->dma_transfer, NULL);
    b->bus = b->dma_transfer;
  }

  int32_t source_offset;
  if (info->next_source >= 0x08000000u && info->next_source < 0x0E000000u && DMA_SRC_CONTROL(info->reg) < 3)
    source_offset = (int32_t)width;
  else source_offset = DMA_OFFSET[DMA_SRC_CONTROL(info->reg)] * (int32_t)width;
  int32_t dest_offset = DMA_OFFSET[DMA_DEST_CONTROL(info->reg)] * (int32_t)width;
  if (source) source += (uint32_t)source_offset;
  dest += (uint32_t)dest_offset;
  --remaining;
  b->performing_dma = 0;

  info->next_count = remaining;
  info->next_source = source;
  info->next_dest = dest;

  for (int i = 0; i < 4; i++) {
    boot_dma *dma = &b->dma[i];
    int32_t time = (int32_t)(dma->when - info->when);
    if (time < 0 && DMA_ENABLE(dma->reg) && dma->next_count) dma->when = info->when;
  }

  if (!remaining) {
    info->next_count = (int32_t)((uint32_t)info->next_count | 0x80000000u);
    if (source_region < REGION_CART0 || dest_region < REGION_CART0) info->when += 2u;
  }
  dma_update(b);
}

static void on_dma_event(rg_bios_boot *b, uint32_t late) {
  boot_dma *dma = &b->dma[b->active_dma];
  if (dma->next_count == dma->count) dma->when = now32(b);
  if ((uint32_t)dma->next_count & 0xFFFFFu) {
    dma_service(b, b->active_dma, dma);
    return;
  }
  dma->next_count = 0;
  int no_repeat = !DMA_REPEAT(dma->reg) || DMA_TIMING(dma->reg) == DMA_TIMING_NOW;
  if (no_repeat) {
    dma->reg &= (uint16_t)~0x8000u;
    b->io[(0x0BA + b->active_dma * 12) >> 1] &= 0x7FE0;
  }
  if (DMA_DEST_CONTROL(dma->reg) == DMA_INCREMENT_RELOAD) dma->next_dest = dma->dest;
  if (DMA_DO_IRQ(dma->reg)) raise_irq(b, IRQ_DMA0 + b->active_dma, late);
  dma_update(b);
}

/* ======================================================================================== */
/* THE TIMERS                                                                               */
/* ======================================================================================== */

static void audio_sample_fifo(rg_bios_boot *b, int fifo_id, int32_t cycles);

static void timer_update_register(rg_bios_boot *b, int timer, int32_t late) {
  boot_timer *t = &b->timers[timer];
  if (!t->enable || t->count_up) return;
  uint32_t tick_mask = (1u << t->prescale_bits) - 1u;
  uint32_t current_time = (now32(b) - (uint32_t)late) & ~tick_mask;
  int32_t increment = (int32_t)(current_time - t->last_event);
  t->last_event = current_time;
  increment >>= t->prescale_bits;
  increment += b->io[(REG_TM0CNT_LO + (timer << 2)) >> 1];
  while (increment >= 0x10000) increment -= 0x10000 - t->reload;
  b->io[(REG_TM0CNT_LO + (timer << 2)) >> 1] = (uint16_t)increment;
  uint32_t next = current_time + ((uint32_t)(0x10000 - increment) << t->prescale_bits);
  next &= ~tick_mask;
  deschedule(b, EVENT_TIMER0 + timer);
  schedule(b, EVENT_TIMER0 + timer, (int32_t)(next - now32(b)));
}

/* A timer ran out: it starts again from its reload, raises its interrupt, clocks the recorded-sound
 * voices that follow it, and counts one on the next timer if that one counts this one's. */
static void timer_overflow(rg_bios_boot *b, int timer, uint32_t late) {
  boot_timer *t = &b->timers[timer];
  if (t->count_up) b->io[(REG_TM0CNT_LO + (timer << 2)) >> 1] = t->reload;
  else timer_update_register(b, timer, (int32_t)late);
  if (t->do_irq) raise_irq(b, IRQ_TIMER0 + timer, late);
  if (b->audio_enable && timer < 2) {
    if ((b->a_left || b->a_right) && b->a_timer == timer) audio_sample_fifo(b, 0, (int32_t)late);
    if ((b->b_left || b->b_right) && b->b_timer == timer) audio_sample_fifo(b, 1, (int32_t)late);
  }
  if (timer < 3) {
    boot_timer *next = &b->timers[timer + 1];
    if (next->count_up && next->enable) {
      uint16_t *count = &b->io[(REG_TM0CNT_LO + ((timer + 1) << 2)) >> 1];
      ++*count;
      if (!*count && next->enable) timer_overflow(b, timer + 1, late);
    }
  }
}

static void timer_write_control(rg_bios_boot *b, int timer, uint16_t control) {
  boot_timer *t = &b->timers[timer];
  timer_update_register(b, timer, 0);
  static const unsigned PRESCALE[4] = {0, 6, 8, 10};
  unsigned prescale = PRESCALE[control & 3u];
  int old_enable = t->enable, old_count_up = t->count_up;
  unsigned old_prescale = t->prescale_bits;
  t->prescale_bits = prescale;
  t->count_up = timer > 0 && (control & 4u);
  t->do_irq = (control & 0x40u) != 0;
  t->enable = (control & 0x80u) != 0;
  int reschedule = 0;
  if (old_enable != t->enable) {
    reschedule = 1;
    if (t->enable) b->io[(REG_TM0CNT_LO + (timer << 2)) >> 1] = t->reload;
  } else if (old_count_up != t->count_up) {
    reschedule = 1;
  } else if (old_prescale != t->prescale_bits) {
    reschedule = 1;
  }
  if (reschedule) {
    deschedule(b, EVENT_TIMER0 + timer);
    if (t->enable && !t->count_up) {
      uint32_t tick_mask = (1u << prescale) - 1u;
      t->last_event = now32(b) & ~tick_mask;
      timer_update_register(b, timer, 0);
    }
  }
}

/* ======================================================================================== */
/* THE SCREEN'S TIMING                                                                      */
/* ======================================================================================== */

static void renderer_draw_scanline(rg_bios_boot *b, int y);
static void renderer_finish_frame(rg_bios_boot *b);

static void keypad_test_irq(rg_bios_boot *b) {
  uint16_t keys_last = b->keys_last, keys_active = 0;
  uint16_t keycnt = b->io[REG_KEYCNT >> 1];
  if (!(keycnt & 0x4000u)) return;
  b->keys_last = keys_active;
  int is_and = (keycnt & 0x8000u) != 0;
  keycnt &= 0x3FFu;
  if (is_and && keycnt == (keys_active & keycnt)) {
    if (keys_last == keys_active) return;
    raise_irq(b, IRQ_KEYPAD, 0);
  } else if (!is_and && (keys_active & keycnt)) {
    raise_irq(b, IRQ_KEYPAD, 0);
  } else {
    b->keys_last = 0x400;
  }
}

/* A line starts: the line counter moves on, and at the bottom of the picture the gap begins, with
 * its interrupt and its copies. */
static void start_hdraw(rg_bios_boot *b, uint32_t late) {
  b->video_next_is_hdraw = 0;
  schedule(b, EVENT_VIDEO, HDRAW_CYCLES - (int32_t)late);
  if (++b->vcount == LINES_IN_FRAME) b->vcount = 0;
  b->io[REG_VCOUNT >> 1] = (uint16_t)b->vcount;
  if (b->vcount < LINES_DRAWN) b->should_stall = 1;

  uint16_t dispstat = b->io[REG_DISPSTAT >> 1];
  dispstat &= (uint16_t)~2u;
  if (b->vcount == (dispstat >> 8)) {
    dispstat |= 4u;
    if (dispstat & 0x20u) raise_irq(b, IRQ_VCOUNTER, late);
  } else {
    dispstat &= (uint16_t)~4u;
  }
  b->io[REG_DISPSTAT >> 1] = dispstat;

  switch (b->vcount) {
  case 0: keypad_test_irq(b); break;
  case LINES_DRAWN:
    b->io[REG_DISPSTAT >> 1] = dispstat | 1u;
    renderer_finish_frame(b);
    dma_run_on(b, DMA_TIMING_VBLANK, -(int32_t)late);
    if (dispstat & 0x08u) raise_irq(b, IRQ_VBLANK, late);
    b->frame_counter++;
    b->early_exit = 1;
    break;
  case LINES_IN_FRAME - 1: b->io[REG_DISPSTAT >> 1] = dispstat & (uint16_t)~1u; break;
  }
}

/* The drawn part of a line ends: the line is drawn, with its copies and its interrupt. */
static void start_hblank(rg_bios_boot *b, uint32_t late) {
  b->video_next_is_hdraw = 1;
  schedule(b, EVENT_VIDEO, HBLANK_CYCLES - (int32_t)late);
  uint16_t dispstat = b->io[REG_DISPSTAT >> 1] | 2u;
  if (b->vcount < LINES_DRAWN) renderer_draw_scanline(b, b->vcount);
  if (b->vcount < LINES_DRAWN) dma_run_on(b, DMA_TIMING_HBLANK, -(int32_t)late);
  if (b->vcount >= 2 && b->vcount < LINES_DRAWN + 2) {
    boot_dma *dma = &b->dma[3];
    if (DMA_ENABLE(dma->reg) && DMA_TIMING(dma->reg) == DMA_TIMING_CUSTOM && !dma->next_count)
      note_unhandled(b, "a copy started by the screen's lines (DMA3 special timing)", 0x040000DEu);
  }
  /* mGBA raises this one six cycles later than the moment the gap begins. */
  if (dispstat & 0x10u) raise_irq(b, IRQ_HBLANK, late - 6u);
  b->should_stall = 0;
  b->io[REG_DISPSTAT >> 1] = dispstat;
}

/* ======================================================================================== */
/* THE REGISTERS                                                                            */
/* ======================================================================================== */

static uint16_t renderer_write_register(rg_bios_boot *b, uint32_t address, uint16_t value);
static void audio_sample(rg_bios_boot *b, uint32_t timestamp);
static uint32_t audio_write_fifo(rg_bios_boot *b, uint32_t address, uint32_t value);
static void audio_write_soundcnt_hi(rg_bios_boot *b, uint16_t value);
static void audio_write_soundcnt_x(rg_bios_boot *b, uint16_t value);
static void audio_write_soundbias(rg_bios_boot *b, uint16_t value);

/* The link port, with nothing plugged into it: what mGBA's port does with no cable. */
enum { SIO_NORMAL_8 = 0, SIO_NORMAL_32 = 1, SIO_MULTI = 2, SIO_UART = 3, SIO_GPIO = 8, SIO_JOYBUS = 12 };

static void sio_switch_mode(rg_bios_boot *b) {
  unsigned mode = ((b->sio_rcnt & 0xC000u) | (b->sio_siocnt & 0x3000u)) >> 12;
  b->sio_mode = (int)(mode < 8 ? mode & 3u : mode & 0xCu);
}

static void sio_write_rcnt(rg_bios_boot *b, uint16_t value) {
  b->sio_rcnt = (uint16_t)((b->sio_rcnt & 0xFu) | (value & ~0xFu));
  sio_switch_mode(b);
}

static void sio_write_siocnt(rg_bios_boot *b, uint16_t value) {
  if ((value ^ b->sio_siocnt) & 0x3000u) {
    b->sio_siocnt = value & 0x3000u;
    sio_switch_mode(b);
  }
  switch (b->sio_mode) {
  case SIO_NORMAL_8:
  case SIO_NORMAL_32:
    value |= 0x0004u;
    if ((value & 0x0081u) == 0x0081u) {
      if (value & 0x4000u) raise_irq(b, IRQ_SIO, 0);
      value &= (uint16_t)~0x0080u;
    }
    break;
  case SIO_MULTI:
    value &= 0xFF83u;
    value |= 0xCu;
    break;
  default: break;
  }
  b->sio_siocnt = value;
}

static uint16_t sio_write_register(rg_bios_boot *b, uint32_t address, uint16_t value) {
  if (b->sio_mode == SIO_JOYBUS) {
    if (address == REG_JOYCNT)
      return (uint16_t)((value & 0x0040u) | (b->io[REG_JOYCNT >> 1] & ~(value & 0x7u) & ~0x0040u));
    if (address == REG_JOYSTAT) return (uint16_t)((value & 0x0030u) | (b->io[REG_JOYSTAT >> 1] & ~0x30u));
  }
  return value;
}

static void io_write16(rg_bios_boot *b, uint32_t address, uint16_t value) {
  if (address < REG_SOUND1CNT_LO && (address > REG_VCOUNT || address < REG_DISPSTAT)) {
    b->io[address >> 1] = renderer_write_register(b, address, value);
    return;
  }
  if (address >= REG_SOUND1CNT_LO && address <= REG_SOUNDCNT_LO && !b->audio_enable) return;

  switch (address) {
  case REG_DISPSTAT:
    value &= 0xFFF8u;
    b->io[REG_DISPSTAT >> 1] = (uint16_t)((b->io[REG_DISPSTAT >> 1] & 7u) | value);
    return;
  case REG_VCOUNT: return;

  /* The tone voices: the start-up does not play them, so their registers are only kept. */
  case REG_SOUND1CNT_LO: audio_sample(b, now32(b)); value &= 0x007Fu; break;
  case REG_SOUND1CNT_HI: audio_sample(b, now32(b)); value &= 0xFFC0u; break;
  case REG_SOUND1CNT_X: audio_sample(b, now32(b)); if (value & 0x8000u) note_unhandled(b, "a tone voice played", 0x04000064u); value &= 0x4000u; break;
  case REG_SOUND2CNT_LO: audio_sample(b, now32(b)); value &= 0xFFC0u; break;
  case REG_SOUND2CNT_HI: audio_sample(b, now32(b)); if (value & 0x8000u) note_unhandled(b, "a tone voice played", 0x0400006Cu); value &= 0x4000u; break;
  case REG_SOUND3CNT_LO: audio_sample(b, now32(b)); value &= 0x00E0u; break;
  case REG_SOUND3CNT_HI: audio_sample(b, now32(b)); value &= 0xE000u; break;
  case REG_SOUND3CNT_X: audio_sample(b, now32(b)); if (value & 0x8000u) note_unhandled(b, "a tone voice played", 0x04000074u); value &= 0x4000u; break;
  case REG_SOUND4CNT_LO: audio_sample(b, now32(b)); value &= 0xFF00u; break;
  case REG_SOUND4CNT_HI: audio_sample(b, now32(b)); if (value & 0x8000u) note_unhandled(b, "a tone voice played", 0x0400007Cu); value &= 0x40FFu; break;
  case REG_SOUNDCNT_LO: audio_sample(b, now32(b)); value &= 0xFF77u; break;
  case REG_SOUNDCNT_HI: audio_write_soundcnt_hi(b, value); value &= 0x770Fu; break;
  case REG_SOUNDCNT_X:
    audio_write_soundcnt_x(b, value);
    value &= 0x0080u;
    value |= b->io[REG_SOUNDCNT_X >> 1] & 0xFu;
    break;
  case REG_SOUNDBIAS:
    value &= 0xC3FEu;
    audio_write_soundbias(b, value);
    break;

  case 0x090: case 0x094: case 0x098: case 0x09C:
    io_write32(b, address, (uint32_t)b->io[(address >> 1) + 1] << 16 | value);
    break;
  case 0x092: case 0x096: case 0x09A: case 0x09E:
    io_write32(b, address - 2u, b->io[(address >> 1) - 1] | (uint32_t)value << 16);
    break;
  case REG_FIFO_A_LO:
  case REG_FIFO_B_LO: io_write32(b, address, (uint32_t)b->io[(address >> 1) + 1] << 16 | value); return;
  case REG_FIFO_A_HI:
  case REG_FIFO_B_HI: io_write32(b, address - 2u, b->io[(address >> 1) - 1] | (uint32_t)value << 16); return;

  case 0x0B0: case 0x0B4: case 0x0BC: case 0x0C0: case 0x0C8: case 0x0CC: case 0x0D4: case 0x0D8:
    io_write32(b, address, (uint32_t)b->io[(address >> 1) + 1] << 16 | value);
    break;
  case 0x0B2: case 0x0B6: case 0x0BE: case 0x0C2: case 0x0CA: case 0x0CE: case 0x0D6: case 0x0DA:
    io_write32(b, address - 2u, b->io[(address >> 1) - 1] | (uint32_t)value << 16);
    break;
  case 0x0B8: dma_write_count(b, 0, value & 0x3FFFu); break;
  case 0x0BA: value = dma_write_control(b, 0, value); break;
  case 0x0C4: dma_write_count(b, 1, value & 0x3FFFu); break;
  case 0x0C6: value = dma_write_control(b, 1, value); break;
  case 0x0D0: dma_write_count(b, 2, value & 0x3FFFu); break;
  case 0x0D2: value = dma_write_control(b, 2, value); break;
  case 0x0DC: dma_write_count(b, 3, value); break;
  case 0x0DE: value = dma_write_control(b, 3, value); break;

  case 0x100: case 0x104: case 0x108: case 0x10C: b->timers[(address - 0x100u) >> 2].reload = value; return;
  case 0x102: case 0x106: case 0x10A: case 0x10E:
    value &= 0x00C7u;
    timer_write_control(b, (int)((address - 0x102u) >> 2), value);
    break;

  case REG_SIOCNT: sio_write_siocnt(b, value); break;
  case REG_RCNT:
    value &= 0xC1FFu;
    sio_write_rcnt(b, value);
    break;
  case 0x154: /* JOY_TRANS */
  case 0x156:
    b->io[REG_JOYSTAT >> 1] |= 0x0008u;
    value = sio_write_register(b, address, value);
    break;
  case REG_SIODATA32_LO:
  case 0x122:
  case 0x12A: /* SIOMLT_SEND */
  case REG_JOYCNT:
  case REG_JOYSTAT:
  case 0x150: /* JOY_RECV */
  case 0x152: value = sio_write_register(b, address, value); break;

  case REG_KEYCNT:
    value &= 0xC3FFu;
    if (b->keys_last < 0x400) b->keys_last &= (uint16_t)(b->io[address >> 1] | ~value);
    b->io[address >> 1] = value;
    keypad_test_irq(b);
    return;
  case REG_WAITCNT:
    value &= 0x5FFFu;
    adjust_waitstates(b, value);
    break;
  case REG_IE:
    b->io[REG_IE >> 1] = value;
    test_irq(b, 1);
    return;
  case REG_IF:
    b->io[REG_IF >> 1] = (uint16_t)(b->io[REG_IF >> 1] & ~value);
    test_irq(b, 1);
    return;
  case REG_IME:
    b->io[REG_IME >> 1] = value & 1u;
    test_irq(b, 1);
    return;
  case REG_MAX: break;
  case REG_POSTFLG:
    if (b->active_region == REGION_BIOS) {
      /* HALTCNT is the high byte. mGBA only lets the BIOS sleep once POSTFLG (the low byte) shows
       * the console has been through its start-up once. */
      if (b->io[address >> 1]) {
        if (value & 0x8000u) note_unhandled(b, "the console stopped (STOP)", 0x04000301u);
        else halt(b);
      }
      value &= (uint16_t)~0x8000u;
    } else {
      return;
    }
    break;
  case REG_EXWAITCNT_HI:
    address = REG_INTERNAL_EXWAITCNT_HI;
    value &= 0xFF00u;
    adjust_ewram_waitstates(b, value);
    break;
  default:
    if (address >= REG_MAX) return;
    break;
  }
  b->io[address >> 1] = value;
}

static void io_write8(rg_bios_boot *b, uint32_t address, uint8_t value) {
  if (address > SIZE_IO) return;
  /* A byte of a tone voice's register goes to the voice as it is, and only part of it can be read
   * back. The voices are not played here: what can be read back is kept, and a voice started is
   * noted. */
  uint16_t *reg = &b->io[(address & ~1u) >> 1];
  switch (address) {
  case 0x062: audio_sample(b, now32(b)); *reg = (uint16_t)((*reg & 0xFF00u) | (value & 0xC0u)); return;
  case 0x063: audio_sample(b, now32(b)); *reg = (uint16_t)((*reg & 0x00C0u) | (uint32_t)value << 8); return;
  case 0x064:
  case 0x06C:
  case 0x072:
  case 0x074:
  case 0x078: audio_sample(b, now32(b)); return;
  case 0x065:
  case 0x06D:
  case 0x075:
    audio_sample(b, now32(b));
    if (value & 0x80u) note_unhandled(b, "a tone voice played", 0x04000000u | address);
    *reg = (uint16_t)((value & 0x40u) << 8);
    return;
  case 0x068: audio_sample(b, now32(b)); *reg = (uint16_t)((*reg & 0xFF00u) | (value & 0xC0u)); return;
  case 0x069: audio_sample(b, now32(b)); *reg = (uint16_t)((*reg & 0x00C0u) | (uint32_t)value << 8); return;
  case 0x073: audio_sample(b, now32(b)); *reg = (uint16_t)((value & 0xE0u) << 8); return;
  case 0x079: audio_sample(b, now32(b)); *reg = (uint16_t)(value << 8); return;
  case 0x07C: audio_sample(b, now32(b)); *reg = (uint16_t)((*reg & 0x4000u) | value); return;
  case 0x07D:
    audio_sample(b, now32(b));
    if (value & 0x80u) note_unhandled(b, "a tone voice played", 0x04000000u | address);
    *reg = (uint16_t)((*reg & 0x00FFu) | (value & 0x40u) << 8);
    return;
  default: break;
  }
  uint16_t shifted = (uint16_t)(value << (8u * (address & 1u)));
  shifted |= (uint16_t)(b->io[(address & (SIZE_IO - 1u)) >> 1] & ~(0xFFu << (8u * (address & 1u))));
  io_write16(b, address & ~1u, shifted);
}

static void io_write32(rg_bios_boot *b, uint32_t address, uint32_t value) {
  switch (address) {
  case 0x090:
  case 0x094:
  case 0x098:
  case 0x09C: break; /* the wave voice's samples: kept as the registers, which nothing here plays */
  case REG_FIFO_A_LO:
  case REG_FIFO_B_LO: value = audio_write_fifo(b, address, value); break;
  case 0x0B0: value = dma_write_source(b, 0, value); break;
  case 0x0B4: value = dma_write_dest(b, 0, value); break;
  case 0x0BC: value = dma_write_source(b, 1, value); break;
  case 0x0C0: value = dma_write_dest(b, 1, value); break;
  case 0x0C8: value = dma_write_source(b, 2, value); break;
  case 0x0CC: value = dma_write_dest(b, 2, value); break;
  case 0x0D4: value = dma_write_source(b, 3, value); break;
  case 0x0D8: value = dma_write_dest(b, 3, value); break;
  default:
    io_write16(b, address, (uint16_t)value);
    io_write16(b, address | 2u, (uint16_t)(value >> 16));
    return;
  }
  b->io[address >> 1] = (uint16_t)value;
  b->io[(address >> 1) + 1] = (uint16_t)(value >> 16);
}

static uint16_t io_read(rg_bios_boot *b, uint32_t address) {
  switch (address) {
  case 0x100:
  case 0x104:
  case 0x108:
  case 0x10C: timer_update_register(b, (int)((address - 0x100u) >> 2), 2); break; /* a read takes two cycles */
  case REG_KEYINPUT: b->io[address >> 1] = 0x3FF; break; /* no buttons held */
  case REG_SIOCNT: return b->sio_siocnt;
  case REG_RCNT: return b->sio_rcnt;
  case 0x150:
  case 0x152: b->io[REG_JOYSTAT >> 1] &= (uint16_t)~0x0002u; break;
  case 0x120: case 0x122: case 0x124: case 0x126: case 0x12A: case REG_JOYCNT: case 0x154: case 0x156: case REG_JOYSTAT:
    break;

  case 0x010: case 0x012: case 0x014: case 0x016: case 0x018: case 0x01A: case 0x01C: case 0x01E:
  case 0x020: case 0x022: case 0x024: case 0x026: case 0x028: case 0x02A: case 0x02C: case 0x02E:
  case 0x030: case 0x032: case 0x034: case 0x036: case 0x038: case 0x03A: case 0x03C: case 0x03E:
  case 0x040: case 0x042: case 0x044: case 0x046: case REG_MOSAIC: case REG_BLDY:
  case 0x0A0: case 0x0A2: case 0x0A4: case 0x0A6:
  case 0x0B0: case 0x0B2: case 0x0B4: case 0x0B6: case 0x0BC: case 0x0BE: case 0x0C0: case 0x0C2:
  case 0x0C8: case 0x0CA: case 0x0CC: case 0x0CE: case 0x0D4: case 0x0D6: case 0x0D8: case 0x0DA:
    return (uint16_t)load_bad(b); /* registers that can only be written */

  case 0x0B8: case 0x0C4: case 0x0D0: case 0x0DC: case REG_MAX: return 0;

  case 0x090: case 0x092: case 0x094: case 0x096: case 0x098: case 0x09A: case 0x09C: case 0x09E:
    note_unhandled(b, "read of the wave voice's samples", 0x04000000u | address);
    break;

  case REG_SOUND1CNT_LO: case REG_SOUND1CNT_HI: case REG_SOUND1CNT_X: case REG_SOUND2CNT_LO:
  case REG_SOUND2CNT_HI: case REG_SOUND3CNT_LO: case REG_SOUND3CNT_HI: case REG_SOUND3CNT_X:
  case REG_SOUND4CNT_LO: case REG_SOUND4CNT_HI: case REG_SOUNDCNT_LO:
    if (!(b->io[REG_SOUNDCNT_X >> 1] & 0x80u)) return 0;
    break;
  case REG_DISPCNT: case REG_GREENSWP: case REG_DISPSTAT: case REG_VCOUNT:
  case 0x008: case 0x00A: case 0x00C: case 0x00E: case REG_WININ: case REG_WINOUT: case REG_BLDCNT: case REG_BLDALPHA:
  case REG_SOUNDCNT_HI: case REG_SOUNDCNT_X: case REG_SOUNDBIAS:
  case 0x0BA: case 0x0C6: case 0x0D2: case 0x0DE:
  case 0x102: case 0x106: case 0x10A: case 0x10E:
  case REG_KEYCNT: case REG_IE: case REG_IF: case REG_WAITCNT: case REG_IME: case REG_POSTFLG:
    break;
  case 0x066: case 0x06A: case 0x06E: case 0x076: case 0x07A: case 0x07E: case 0x086: case 0x08A:
  case 0x136: case 0x142: case 0x15A: case 0x206: case 0x302: return 0;
  case REG_EXWAITCNT_LO:
  case REG_EXWAITCNT_HI: address = address - (uint32_t)REG_EXWAITCNT_LO + (uint32_t)REG_INTERNAL_EXWAITCNT_LO; break;
  default: return (uint16_t)load_bad(b);
  }
  return b->io[address >> 1];
}

/* ======================================================================================== */
/* THE INSTRUCTIONS                                                                         */
/* ======================================================================================== */

#define ARM_PREFETCH_CYCLES (1 + b->active_seq32)
#define THUMB_PREFETCH_CYCLES (1 + b->active_seq16)

static inline int flag(const rg_bios_boot *b, uint32_t bit) { return (b->cpsr & bit) != 0; }

static inline void set_nz(rg_bios_boot *b, uint32_t d) {
  b->cpsr &= ~(PSR_N | PSR_Z);
  if (d & 0x80000000u) b->cpsr |= PSR_N;
  if (!d) b->cpsr |= PSR_Z;
}

static inline void set_flag(rg_bios_boot *b, uint32_t bit, int on) {
  if (on) b->cpsr |= bit;
  else b->cpsr &= ~bit;
}

static void set_addition_flags(rg_bios_boot *b, uint32_t m, uint32_t n, uint32_t d) {
  b->cpsr &= ~(PSR_N | PSR_Z | PSR_C | PSR_V);
  set_nz(b, d);
  set_flag(b, PSR_C, (m >> 31) + (n >> 31) > (d >> 31));
  set_flag(b, PSR_V, !((m ^ n) >> 31) && ((m ^ d) >> 31));
}

static void set_subtraction_flags(rg_bios_boot *b, uint32_t m, uint32_t n, uint32_t d) {
  b->cpsr &= ~(PSR_N | PSR_Z | PSR_C | PSR_V);
  set_nz(b, d);
  set_flag(b, PSR_C, m >= n);
  set_flag(b, PSR_V, ((m ^ n) >> 31) && ((m ^ d) >> 31));
}

static void set_subtraction_carry_flags(rg_bios_boot *b, uint32_t m, uint32_t n, uint32_t d, uint32_t borrow) {
  set_nz(b, d);
  set_flag(b, PSR_C, (uint64_t)m >= (uint64_t)n + borrow);
  set_flag(b, PSR_V, ((m ^ n) >> 31) && ((m ^ d) >> 31));
}

static int condition_passes(const rg_bios_boot *b, unsigned condition) {
  int n = flag(b, PSR_N), z = flag(b, PSR_Z), c = flag(b, PSR_C), v = flag(b, PSR_V);
  switch (condition) {
  case 0x0: return z;
  case 0x1: return !z;
  case 0x2: return c;
  case 0x3: return !c;
  case 0x4: return n;
  case 0x5: return !n;
  case 0x6: return v;
  case 0x7: return !v;
  case 0x8: return c && !z;
  case 0x9: return !c || z;
  case 0xA: return n == v;
  case 0xB: return n != v;
  case 0xC: return !z && n == v;
  case 0xD: return z || n != v;
  case 0xE: return 1;
  default: return 0;
  }
}

/* The ARM's second operand: an immediate turned, or a register shifted by an immediate or by
 * another register (which costs a cycle, and reads the program counter one word further on). */
static void arm_shifter(rg_bios_boot *b, uint32_t opcode) {
  if (opcode & 0x02000000u) {
    unsigned rotate = (opcode >> 7) & 0x1Eu;
    uint32_t immediate = opcode & 0xFFu;
    if (!rotate) {
      b->shifter_operand = immediate;
      b->shifter_carry = flag(b, PSR_C);
    } else {
      b->shifter_operand = ror32(immediate, rotate);
      b->shifter_carry = (int)(b->shifter_operand >> 31);
    }
    return;
  }
  unsigned rm = opcode & 0xFu;
  unsigned type = (opcode >> 5) & 3u;
  if (opcode & 0x10u) {
    unsigned rs = (opcode >> 8) & 0xFu;
    ++b->cycles;
    uint32_t value = b->r[rm];
    if (rm == REG_PC) value += 4u;
    unsigned shift = b->r[rs] & 0xFFu;
    switch (type) {
    case 0: /* LSL */
      if (!shift) {
        b->shifter_operand = value;
        b->shifter_carry = flag(b, PSR_C);
      } else if (shift < 32) {
        b->shifter_operand = value << shift;
        b->shifter_carry = (int)((value >> (32 - shift)) & 1u);
      } else if (shift == 32) {
        b->shifter_operand = 0;
        b->shifter_carry = (int)(value & 1u);
      } else {
        b->shifter_operand = 0;
        b->shifter_carry = 0;
      }
      break;
    case 1: /* LSR */
      if (!shift) {
        b->shifter_operand = value;
        b->shifter_carry = flag(b, PSR_C);
      } else if (shift < 32) {
        b->shifter_operand = value >> shift;
        b->shifter_carry = (int)((value >> (shift - 1)) & 1u);
      } else if (shift == 32) {
        b->shifter_operand = 0;
        b->shifter_carry = (int)(value >> 31);
      } else {
        b->shifter_operand = 0;
        b->shifter_carry = 0;
      }
      break;
    case 2: /* ASR */
      if (!shift) {
        b->shifter_operand = value;
        b->shifter_carry = flag(b, PSR_C);
      } else if (shift < 32) {
        b->shifter_operand = asr32(value, shift);
        b->shifter_carry = (int)((asr32(value, shift - 1)) & 1u);
      } else if (b->r[rm] >> 31) {
        b->shifter_operand = 0xFFFFFFFFu;
        b->shifter_carry = 1;
      } else {
        b->shifter_operand = 0;
        b->shifter_carry = 0;
      }
      break;
    default: { /* ROR */
      unsigned rotate = shift & 0x1Fu;
      if (!shift) {
        b->shifter_operand = value;
        b->shifter_carry = flag(b, PSR_C);
      } else if (rotate) {
        b->shifter_operand = ror32(value, rotate);
        b->shifter_carry = (int)((value >> (rotate - 1)) & 1u);
      } else {
        b->shifter_operand = value;
        b->shifter_carry = (int)(value >> 31);
      }
    }
    }
    return;
  }
  unsigned immediate = (opcode >> 7) & 0x1Fu;
  uint32_t value = b->r[rm];
  switch (type) {
  case 0:
    if (!immediate) {
      b->shifter_operand = value;
      b->shifter_carry = flag(b, PSR_C);
    } else {
      b->shifter_operand = value << immediate;
      b->shifter_carry = (int)((value >> (32 - immediate)) & 1u);
    }
    break;
  case 1:
    if (immediate) {
      b->shifter_operand = value >> immediate;
      b->shifter_carry = (int)((value >> (immediate - 1)) & 1u);
    } else {
      b->shifter_operand = 0;
      b->shifter_carry = (int)(value >> 31);
    }
    break;
  case 2:
    if (immediate) {
      b->shifter_operand = asr32(value, immediate);
      b->shifter_carry = (int)((value >> (immediate - 1)) & 1u);
    } else {
      b->shifter_carry = (int)(value >> 31);
      b->shifter_operand = b->shifter_carry ? 0xFFFFFFFFu : 0u;
    }
    break;
  default:
    if (immediate) {
      b->shifter_operand = ror32(value, immediate);
      b->shifter_carry = (int)((value >> (immediate - 1)) & 1u);
    } else { /* RRX */
      b->shifter_operand = (uint32_t)flag(b, PSR_C) << 31 | value >> 1;
      b->shifter_carry = (int)(value & 1u);
    }
  }
}

/* An ALU instruction with S that writes the program counter returns from an exception: the status
 * comes back from where the exception kept it. */
static int restore_cpsr_if_pc(rg_bios_boot *b, unsigned rd) {
  if (rd == REG_PC && mode_has_spsr((int)(b->cpsr & PSR_MODE))) {
    b->cpsr = b->spsr;
    read_cpsr(b);
    return 1;
  }
  return 0;
}

static void arm_data_processing(rg_bios_boot *b, uint32_t opcode, int32_t *current) {
  arm_shifter(b, opcode);
  unsigned rd = (opcode >> 12) & 0xFu, rn = (opcode >> 16) & 0xFu, op = (opcode >> 21) & 0xFu;
  int s = (opcode & 0x00100000u) != 0;
  uint32_t n = b->r[rn];
  if (rn == REG_PC && (opcode & 0x02000010u) == 0x00000010u) n += 4u;
  uint32_t m = b->shifter_operand, d = 0;
  int writes = 1;
  uint32_t carry_in = flag(b, PSR_C) ? 1u : 0u;
  switch (op) {
  case 0x0: d = n & m; break;
  case 0x1: d = n ^ m; break;
  case 0x2: d = n - m; break;
  case 0x3: d = m - n; break;
  case 0x4: d = n + m; break;
  case 0x5: d = n + m + carry_in; break;
  case 0x6: d = n - m - (carry_in ^ 1u); break;
  case 0x7: d = m - n - (carry_in ^ 1u); break;
  case 0x8: d = n & m; writes = 0; break;
  case 0x9: d = n ^ m; writes = 0; break;
  case 0xA: d = n - m; writes = 0; break;
  case 0xB: d = n + m; writes = 0; break;
  case 0xC: d = n | m; break;
  case 0xD: d = m; break;
  case 0xE: d = n & ~m; break;
  default: d = ~m; break;
  }
  if (writes) b->r[rd] = d;
  if (s && !restore_cpsr_if_pc(b, rd)) {
    switch (op) {
    case 0x2:
    case 0xA: set_subtraction_flags(b, n, m, d); break;
    case 0x3: set_subtraction_flags(b, m, n, d); break;
    case 0x4:
    case 0x5:
    case 0xB: set_addition_flags(b, n, m, d); break;
    case 0x6: set_subtraction_carry_flags(b, n, m, d, carry_in ^ 1u); break;
    case 0x7: set_subtraction_carry_flags(b, m, n, d, carry_in ^ 1u); break;
    default:
      set_nz(b, d);
      set_flag(b, PSR_C, b->shifter_carry);
    }
  }
  if (rd == REG_PC) *current += write_pc(b);
}

/* How long a multiply takes depends on how many bytes of the multiplier are not all sign. */
static int32_t multiply_wait(uint32_t value, int32_t wait, int is_signed) {
  if (is_signed) {
    if ((value & 0xFFFFFF00u) == 0xFFFFFF00u || !(value & 0xFFFFFF00u)) return wait + 1;
    if ((value & 0xFFFF0000u) == 0xFFFF0000u || !(value & 0xFFFF0000u)) return wait + 2;
    if ((value & 0xFF000000u) == 0xFF000000u || !(value & 0xFF000000u)) return wait + 3;
    return wait + 4;
  }
  if (!(value & 0xFFFFFF00u)) return wait + 1;
  if (!(value & 0xFFFF0000u)) return wait + 2;
  if (!(value & 0xFF000000u)) return wait + 3;
  return wait + 4;
}

static void arm_multiply(rg_bios_boot *b, uint32_t opcode, int32_t *current) {
  unsigned rd = (opcode >> 16) & 0xFu, rn = (opcode >> 12) & 0xFu, rs = (opcode >> 8) & 0xFu, rm = opcode & 0xFu;
  int accumulate = (opcode & 0x00200000u) != 0, s = (opcode & 0x00100000u) != 0;
  if (rd != REG_PC) {
    *current += multiply_wait(b->r[rs], accumulate ? 1 : 0, 1);
    uint32_t d = b->r[rm] * b->r[rs] + (accumulate ? b->r[rn] : 0u);
    b->r[rd] = d;
    if (s) {
      set_nz(b, d);
      set_flag(b, PSR_C, b->shifter_carry);
    }
  }
  *current += b->active_nonseq32 - b->active_seq32;
}

static void arm_multiply_long(rg_bios_boot *b, uint32_t opcode, int32_t *current) {
  unsigned rd_hi = (opcode >> 16) & 0xFu, rd_lo = (opcode >> 12) & 0xFu, rs = (opcode >> 8) & 0xFu, rm = opcode & 0xFu;
  int is_signed = (opcode & 0x00400000u) != 0, accumulate = (opcode & 0x00200000u) != 0, s = (opcode & 0x00100000u) != 0;
  if (rd_hi != REG_PC && rd_lo != REG_PC) {
    *current += multiply_wait(b->r[rs], accumulate ? 2 : 1, is_signed);
    uint64_t product;
    if (is_signed) {
      int64_t a = (int64_t)(int32_t)b->r[rm], c = (int64_t)(int32_t)b->r[rs];
      product = (uint64_t)(a * c);
    } else {
      product = (uint64_t)b->r[rm] * (uint64_t)b->r[rs];
    }
    uint32_t lo = (uint32_t)product, hi = (uint32_t)(product >> 32);
    if (accumulate) {
      uint64_t sum = product + (uint64_t)b->r[rd_lo];
      lo = (uint32_t)sum;
      hi = b->r[rd_hi] + (uint32_t)(sum >> 32);
      if (!is_signed) hi = b->r[rd_hi] + (uint32_t)(((uint64_t)b->r[rm] * (uint64_t)b->r[rs] + (uint64_t)b->r[rd_lo]) >> 32);
    }
    b->r[rd_lo] = lo;
    b->r[rd_hi] = hi;
    if (s) {
      b->cpsr &= ~(PSR_N | PSR_Z);
      if (hi & 0x80000000u) b->cpsr |= PSR_N;
      if (!(hi | lo)) b->cpsr |= PSR_Z;
    }
  }
  *current += b->active_nonseq32 - b->active_seq32;
}

static void arm_swap(rg_bios_boot *b, uint32_t opcode, int32_t *current) {
  unsigned rm = opcode & 0xFu, rd = (opcode >> 12) & 0xFu, rn = (opcode >> 16) & 0xFu;
  if (opcode & 0x00400000u) {
    uint32_t d = load8(b, b->r[rn], current);
    store8(b, b->r[rn], (uint8_t)b->r[rm], current);
    b->r[rd] = d;
  } else {
    uint32_t d = load32(b, b->r[rn], current);
    store32(b, b->r[rn], b->r[rm], current);
    b->r[rd] = d;
  }
}

static void arm_msr(rg_bios_boot *b, uint32_t opcode) {
  int to_spsr = (opcode & 0x00400000u) != 0;
  uint32_t operand;
  if (opcode & 0x02000000u) operand = ror32(opcode & 0xFFu, (opcode >> 7) & 0x1Eu);
  else operand = b->r[opcode & 0xFu];
  uint32_t mask = ((opcode & 0x00010000u) ? 0x000000FFu : 0u) | ((opcode & 0x00080000u) ? 0xFF000000u : 0u);
  if (to_spsr) {
    mask &= PSR_USER_MASK | PSR_PRIV_MASK | PSR_STATE_MASK;
    b->spsr = (b->spsr & ~mask) | (operand & mask) | 0x10u;
    return;
  }
  if (mask & PSR_USER_MASK) b->cpsr = (b->cpsr & ~PSR_USER_MASK) | (operand & PSR_USER_MASK);
  if (mask & PSR_STATE_MASK) b->cpsr = (b->cpsr & ~PSR_STATE_MASK) | (operand & PSR_STATE_MASK);
  if (b->privilege_mode != MODE_USER && (mask & PSR_PRIV_MASK)) {
    set_privilege_mode(b, (int)((operand & 0xFu) | 0x10u));
    b->cpsr = (b->cpsr & ~PSR_PRIV_MASK) | (operand & PSR_PRIV_MASK);
  }
  read_cpsr(b);
  if (b->thumb) {
    b->prefetch[0] = 0x46C0; /* a THUMB nop */
    b->prefetch[1] &= 0xFFFFu;
    b->r[REG_PC] += 2u;
  } else {
    b->prefetch[0] = fetch(b, b->r[REG_PC] - 4u, 4);
    b->prefetch[1] = fetch(b, b->r[REG_PC], 4);
  }
}

/* LDR, STR, LDRB, STRB, and the halfword and signed ones. */
static void arm_single_transfer(rg_bios_boot *b, uint32_t opcode, int32_t *current, int halfword) {
  unsigned rn = (opcode >> 16) & 0xFu, rd = (opcode >> 12) & 0xFu, rm = opcode & 0xFu;
  int pre = (opcode & 0x01000000u) != 0, up = (opcode & 0x00800000u) != 0, writeback_bit = (opcode & 0x00200000u) != 0;
  int load = (opcode & 0x00100000u) != 0;
  uint32_t offset;
  if (halfword) {
    if (opcode & 0x00400000u) offset = ((opcode >> 4) & 0xF0u) | (opcode & 0xFu);
    else offset = b->r[rm];
  } else if (!(opcode & 0x02000000u)) {
    offset = opcode & 0xFFFu;
  } else {
    unsigned shift = (opcode >> 7) & 0x1Fu;
    uint32_t value = b->r[rm];
    switch ((opcode >> 5) & 3u) {
    case 0: offset = value << shift; break;
    case 1: offset = shift ? value >> shift : 0u; break;
    case 2: offset = shift ? asr32(value, shift) : asr32(value, 31); break;
    default: offset = shift ? ror32(value, shift) : ((uint32_t)flag(b, PSR_C) << 31 | value >> 1); break;
    }
  }
  uint32_t indexed = up ? b->r[rn] + offset : b->r[rn] - offset;
  uint32_t address = pre ? indexed : b->r[rn];
  int writeback = !pre || writeback_bit;
  uint32_t d = b->r[rd];
  if (rd == REG_PC) d += 4u;

  if (load) {
    if (writeback) {
      b->r[rn] = indexed;
      if (rn == REG_PC) *current += arm_write_pc(b);
    }
    uint32_t value;
    if (!halfword) {
      value = (opcode & 0x00400000u) ? load8(b, address, current) : load32(b, address, current);
    } else {
      switch ((opcode >> 5) & 3u) {
      case 1: value = load16(b, address, current); break;
      case 2: value = sign_extend8(load8(b, address, current)); break;
      default:
        value = (address & 1u) ? sign_extend8(load16(b, address, current)) : sign_extend16(load16(b, address, current));
        break;
      }
    }
    b->r[rd] = value;
    *current += b->active_nonseq32 - b->active_seq32;
    if (rd == REG_PC) *current += arm_write_pc(b);
  } else {
    if (!halfword) {
      if (opcode & 0x00400000u) store8(b, address, (uint8_t)d, current);
      else store32(b, address, d, current);
    } else {
      store16(b, address, (uint16_t)d, current);
    }
    *current += b->active_nonseq32 - b->active_seq32;
    if (writeback) {
      b->r[rn] = indexed;
      if (rn == REG_PC) *current += arm_write_pc(b);
    }
  }
}

static void arm_block_transfer(rg_bios_boot *b, uint32_t opcode, int32_t *current) {
  unsigned rn = (opcode >> 16) & 0xFu;
  uint32_t rs = opcode & 0xFFFFu;
  int pre = (opcode & 0x01000000u) != 0, up = (opcode & 0x00800000u) != 0, user = (opcode & 0x00400000u) != 0;
  int writeback = (opcode & 0x00200000u) != 0, load = (opcode & 0x00100000u) != 0;
  int direction = (pre ? LSM_B : 0) | (up ? 0 : LSM_D);
  uint32_t address = b->r[rn];
  int saved_mode = b->privilege_mode;
  if (load) {
    int banked_load = user && !(rs & 0x8000u) && rs;
    if (banked_load) set_privilege_mode(b, MODE_SYSTEM);
    address = load_multiple(b, address, rs, direction, current);
    if (writeback && !((1u << rn) & rs)) b->r[rn] = address;
    if (user) {
      if (banked_load) {
        set_privilege_mode(b, saved_mode);
      } else if (mode_has_spsr((int)(b->cpsr & PSR_MODE))) {
        b->cpsr = b->spsr;
        read_cpsr(b);
      }
    }
    *current += b->active_nonseq32 - b->active_seq32;
    if ((rs & 0x8000u) || !rs) *current += write_pc(b);
  } else {
    if (user) set_privilege_mode(b, MODE_SYSTEM);
    address = store_multiple(b, address, rs, direction, current);
    if (writeback) b->r[rn] = address;
    if (user) set_privilege_mode(b, saved_mode);
    *current += b->active_nonseq32 - b->active_seq32;
  }
}

static void arm_execute(rg_bios_boot *b, uint32_t opcode) {
  int32_t current = ARM_PREFETCH_CYCLES;
  switch ((opcode >> 25) & 7u) {
  case 0:
    if ((opcode & 0x0FC000F0u) == 0x00000090u) {
      arm_multiply(b, opcode, &current);
    } else if ((opcode & 0x0F8000F0u) == 0x00800090u) {
      arm_multiply_long(b, opcode, &current);
    } else if ((opcode & 0x0FB00FF0u) == 0x01000090u) {
      arm_swap(b, opcode, &current);
    } else if ((opcode & 0x0FF000F0u) == 0x01200010u) { /* BX */
      unsigned rm = opcode & 0xFu;
      set_instruction_set(b, (b->r[rm] & 1u) != 0);
      b->r[REG_PC] = b->r[rm] & ~1u;
      current += write_pc(b);
    } else if ((opcode & 0x90u) == 0x90u && (opcode & 0x60u)) {
      arm_single_transfer(b, opcode, &current, 1);
    } else if ((opcode & 0x01900000u) == 0x01000000u) { /* the status registers */
      if (opcode & 0x00200000u) {
        arm_msr(b, opcode);
      } else {
        unsigned rd = (opcode >> 12) & 0xFu;
        b->r[rd] = (opcode & 0x00400000u) ? b->spsr : b->cpsr;
      }
    } else {
      arm_data_processing(b, opcode, &current);
    }
    break;
  case 1:
    if ((opcode & 0x01900000u) == 0x01000000u) {
      if (opcode & 0x00200000u) arm_msr(b, opcode);
      else arm_raise_undefined(b);
    } else {
      arm_data_processing(b, opcode, &current);
    }
    break;
  case 2: arm_single_transfer(b, opcode, &current, 0); break;
  case 3:
    if (opcode & 0x10u) arm_raise_undefined(b);
    else arm_single_transfer(b, opcode, &current, 0);
    break;
  case 4: arm_block_transfer(b, opcode, &current); break;
  case 5: {
    uint32_t offset = (opcode & 0x00FFFFFFu) << 8;
    if (opcode & 0x01000000u) b->r[REG_LR] = b->r[REG_PC] - 4u;
    b->r[REG_PC] += asr32(offset, 6);
    current += arm_write_pc(b);
    break;
  }
  case 6: note_unhandled(b, "coprocessor instruction", b->r[REG_PC] - 8u); break;
  default:
    if (opcode & 0x01000000u) arm_raise_swi(b);
    else note_unhandled(b, "coprocessor instruction", b->r[REG_PC] - 8u);
    break;
  }
  b->cycles += current;
}

static void arm_step(rg_bios_boot *b) {
  uint32_t opcode = b->prefetch[0];
  b->prefetch[0] = b->prefetch[1];
  b->r[REG_PC] += 4u;
  b->prefetch[1] = fetch(b, b->r[REG_PC], 4);
  unsigned condition = opcode >> 28;
  if (condition != 0xE && !condition_passes(b, condition)) {
    b->cycles += ARM_PREFETCH_CYCLES;
    return;
  }
  arm_execute(b, opcode);
}

/* --- THUMB --- */

static void thumb_alu(rg_bios_boot *b, uint32_t opcode, int32_t *current) {
  unsigned rd = opcode & 7u, rn = (opcode >> 3) & 7u;
  uint32_t d = b->r[rd], n = b->r[rn];
  switch ((opcode >> 6) & 0xFu) {
  case 0x0: b->r[rd] = d & n; set_nz(b, b->r[rd]); break;
  case 0x1: b->r[rd] = d ^ n; set_nz(b, b->r[rd]); break;
  case 0x2: { /* LSL */
    unsigned rs = n & 0xFFu;
    if (rs) {
      if (rs < 32) {
        set_flag(b, PSR_C, (d >> (32 - rs)) & 1u);
        b->r[rd] = d << rs;
      } else {
        set_flag(b, PSR_C, rs > 32 ? 0 : (d & 1u));
        b->r[rd] = 0;
      }
    }
    ++*current;
    set_nz(b, b->r[rd]);
    break;
  }
  case 0x3: { /* LSR */
    unsigned rs = n & 0xFFu;
    if (rs) {
      if (rs < 32) {
        set_flag(b, PSR_C, (d >> (rs - 1)) & 1u);
        b->r[rd] = d >> rs;
      } else {
        set_flag(b, PSR_C, rs > 32 ? 0 : (int)(d >> 31));
        b->r[rd] = 0;
      }
    }
    ++*current;
    set_nz(b, b->r[rd]);
    break;
  }
  case 0x4: { /* ASR */
    unsigned rs = n & 0xFFu;
    if (rs) {
      if (rs < 32) {
        set_flag(b, PSR_C, asr32(d, rs - 1) & 1u);
        b->r[rd] = asr32(d, rs);
      } else {
        set_flag(b, PSR_C, (int)(d >> 31));
        b->r[rd] = (d >> 31) ? 0xFFFFFFFFu : 0u;
      }
    }
    ++*current;
    set_nz(b, b->r[rd]);
    break;
  }
  case 0x5: { /* ADC */
    uint32_t result = d + n + (flag(b, PSR_C) ? 1u : 0u);
    b->r[rd] = result;
    set_addition_flags(b, d, n, result);
    break;
  }
  case 0x6: { /* SBC */
    uint32_t borrow = flag(b, PSR_C) ? 0u : 1u;
    uint32_t result = d - n - borrow;
    b->r[rd] = result;
    set_subtraction_carry_flags(b, d, n, result, borrow);
    break;
  }
  case 0x7: { /* ROR */
    unsigned rs = n & 0xFFu;
    if (rs) {
      unsigned r4 = rs & 0x1Fu;
      if (r4) {
        set_flag(b, PSR_C, (d >> (r4 - 1)) & 1u);
        b->r[rd] = ror32(d, r4);
      } else {
        set_flag(b, PSR_C, (int)(d >> 31));
      }
    }
    ++*current;
    set_nz(b, b->r[rd]);
    break;
  }
  case 0x8: set_nz(b, d & n); break; /* TST */
  case 0x9: b->r[rd] = 0u - n; set_subtraction_flags(b, 0, n, b->r[rd]); break; /* NEG */
  case 0xA: set_subtraction_flags(b, d, n, d - n); break;                      /* CMP */
  case 0xB: set_addition_flags(b, d, n, d + n); break;                         /* CMN */
  case 0xC: b->r[rd] = d | n; set_nz(b, b->r[rd]); break;
  case 0xD: /* MUL */
    *current += multiply_wait(d, 0, 1);
    b->r[rd] = d * n;
    set_nz(b, b->r[rd]);
    *current += b->active_nonseq16 - b->active_seq16;
    break;
  case 0xE: b->r[rd] = d & ~n; set_nz(b, b->r[rd]); break;
  default: b->r[rd] = ~n; set_nz(b, b->r[rd]); break;
  }
}

static void thumb_execute(rg_bios_boot *b, uint32_t opcode) {
  int32_t current = THUMB_PREFETCH_CYCLES;
  switch (opcode >> 11) {
  case 0x00: case 0x01: case 0x02: { /* LSL, LSR, ASR by an immediate */
    unsigned immediate = (opcode >> 6) & 0x1Fu, rd = opcode & 7u, rm = (opcode >> 3) & 7u;
    uint32_t value = b->r[rm];
    switch (opcode >> 11) {
    case 0x00:
      if (!immediate) {
        b->r[rd] = value;
      } else {
        set_flag(b, PSR_C, (value >> (32 - immediate)) & 1u);
        b->r[rd] = value << immediate;
      }
      break;
    case 0x01:
      if (!immediate) {
        set_flag(b, PSR_C, (int)(value >> 31));
        b->r[rd] = 0;
      } else {
        set_flag(b, PSR_C, (value >> (immediate - 1)) & 1u);
        b->r[rd] = value >> immediate;
      }
      break;
    default:
      if (!immediate) {
        set_flag(b, PSR_C, (int)(value >> 31));
        b->r[rd] = (value >> 31) ? 0xFFFFFFFFu : 0u;
      } else {
        set_flag(b, PSR_C, (value >> (immediate - 1)) & 1u);
        b->r[rd] = asr32(value, immediate);
      }
    }
    set_nz(b, b->r[rd]);
    break;
  }
  case 0x03: { /* ADD and SUB, three registers or a register and a small number */
    unsigned rd = opcode & 7u, rn = (opcode >> 3) & 7u;
    uint32_t m = b->r[rn];
    uint32_t n = (opcode & 0x0400u) ? (opcode >> 6) & 7u : b->r[(opcode >> 6) & 7u];
    if (opcode & 0x0200u) {
      b->r[rd] = m - n;
      set_subtraction_flags(b, m, n, b->r[rd]);
    } else {
      b->r[rd] = m + n;
      set_addition_flags(b, m, n, b->r[rd]);
    }
    break;
  }
  case 0x04: { /* MOV */
    unsigned rd = (opcode >> 8) & 7u;
    b->r[rd] = opcode & 0xFFu;
    set_nz(b, b->r[rd]);
    break;
  }
  case 0x05: { /* CMP */
    unsigned rd = (opcode >> 8) & 7u;
    uint32_t m = b->r[rd], n = opcode & 0xFFu;
    set_subtraction_flags(b, m, n, m - n);
    break;
  }
  case 0x06: { /* ADD */
    unsigned rd = (opcode >> 8) & 7u;
    uint32_t m = b->r[rd], n = opcode & 0xFFu;
    b->r[rd] = m + n;
    set_addition_flags(b, m, n, b->r[rd]);
    break;
  }
  case 0x07: { /* SUB */
    unsigned rd = (opcode >> 8) & 7u;
    uint32_t m = b->r[rd], n = opcode & 0xFFu;
    b->r[rd] = m - n;
    set_subtraction_flags(b, m, n, b->r[rd]);
    break;
  }
  case 0x08:
    if (!(opcode & 0x0400u)) {
      thumb_alu(b, opcode, &current);
    } else { /* the high registers, and BX */
      unsigned rd = (opcode & 7u) | ((opcode >> 4) & 8u), rm = (opcode >> 3) & 0xFu;
      switch ((opcode >> 8) & 3u) {
      case 0:
        b->r[rd] += b->r[rm];
        if (rd == REG_PC) current += thumb_write_pc(b);
        break;
      case 1: {
        uint32_t m = b->r[rd], n = b->r[rm];
        set_subtraction_flags(b, m, n, m - n);
        break;
      }
      case 2:
        b->r[rd] = b->r[rm];
        if (rd == REG_PC) current += thumb_write_pc(b);
        break;
      default:
        set_instruction_set(b, (b->r[rm] & 1u) != 0);
        b->r[REG_PC] = b->r[rm] & ~1u;
        current += write_pc(b);
        break;
      }
    }
    break;
  case 0x09: { /* LDR relative to the program counter */
    unsigned rd = (opcode >> 8) & 7u;
    b->r[rd] = load32(b, (b->r[REG_PC] & ~3u) + ((opcode & 0xFFu) << 2), &current);
    current += b->active_nonseq16 - b->active_seq16;
    break;
  }
  case 0x0A: case 0x0B: { /* loads and stores at two registers added */
    unsigned rd = opcode & 7u, rn = (opcode >> 3) & 7u, rm = (opcode >> 6) & 7u;
    uint32_t address = b->r[rn] + b->r[rm];
    switch ((opcode >> 9) & 7u) {
    case 0: store32(b, address, b->r[rd], &current); break;
    case 1: store16(b, address, (uint16_t)b->r[rd], &current); break;
    case 2: store8(b, address, (uint8_t)b->r[rd], &current); break;
    case 3: b->r[rd] = sign_extend8(load8(b, address, &current)); break;
    case 4: b->r[rd] = load32(b, address, &current); break;
    case 5: b->r[rd] = load16(b, address, &current); break;
    case 6: b->r[rd] = load8(b, address, &current); break;
    default:
      b->r[rd] = (address & 1u) ? sign_extend8(load16(b, address, &current)) : sign_extend16(load16(b, address, &current));
      break;
    }
    current += b->active_nonseq16 - b->active_seq16;
    break;
  }
  case 0x0C: case 0x0D: case 0x0E: case 0x0F: case 0x10: case 0x11: { /* loads and stores at a register and a number */
    unsigned immediate = (opcode >> 6) & 0x1Fu, rd = opcode & 7u, rm = (opcode >> 3) & 7u;
    switch (opcode >> 11) {
    case 0x0C: store32(b, b->r[rm] + immediate * 4u, b->r[rd], &current); break;
    case 0x0D: b->r[rd] = load32(b, b->r[rm] + immediate * 4u, &current); break;
    case 0x0E: store8(b, b->r[rm] + immediate, (uint8_t)b->r[rd], &current); break;
    case 0x0F: b->r[rd] = load8(b, b->r[rm] + immediate, &current); break;
    case 0x10: store16(b, b->r[rm] + immediate * 2u, (uint16_t)b->r[rd], &current); break;
    default: b->r[rd] = load16(b, b->r[rm] + immediate * 2u, &current); break;
    }
    current += b->active_nonseq16 - b->active_seq16;
    break;
  }
  case 0x12: case 0x13: { /* loads and stores relative to the stack */
    unsigned rd = (opcode >> 8) & 7u;
    uint32_t address = b->r[REG_SP] + ((opcode & 0xFFu) << 2);
    if (opcode & 0x0800u) b->r[rd] = load32(b, address, &current);
    else store32(b, address, b->r[rd], &current);
    current += b->active_nonseq16 - b->active_seq16;
    break;
  }
  case 0x14: b->r[(opcode >> 8) & 7u] = (b->r[REG_PC] & ~3u) + ((opcode & 0xFFu) << 2); break;
  case 0x15: b->r[(opcode >> 8) & 7u] = b->r[REG_SP] + ((opcode & 0xFFu) << 2); break;
  case 0x16: case 0x17:
    if ((opcode & 0x0F00u) == 0x0000u) { /* ADD or SUB to the stack pointer */
      if (opcode & 0x80u) b->r[REG_SP] -= (opcode & 0x7Fu) << 2;
      else b->r[REG_SP] += (opcode & 0x7Fu) << 2;
    } else if ((opcode & 0x0600u) == 0x0400u) { /* PUSH and POP */
      uint32_t rs = opcode & 0xFFu;
      if (opcode & 0x0800u) {
        if (opcode & 0x0100u) rs |= 1u << REG_PC;
        uint32_t address = load_multiple(b, b->r[REG_SP], rs, 0, &current);
        current += b->active_nonseq16 - b->active_seq16;
        b->r[REG_SP] = address;
        if (opcode & 0x0100u) current += thumb_write_pc(b);
      } else {
        if (opcode & 0x0100u) rs |= 1u << REG_LR;
        uint32_t address = store_multiple(b, b->r[REG_SP], rs, LSM_D | LSM_B, &current);
        current += b->active_nonseq16 - b->active_seq16;
        b->r[REG_SP] = address;
      }
    } else {
      arm_raise_undefined(b);
    }
    break;
  case 0x18: case 0x19: { /* STMIA and LDMIA */
    unsigned rn = (opcode >> 8) & 7u;
    uint32_t rs = opcode & 0xFFu;
    if (opcode & 0x0800u) {
      uint32_t address = load_multiple(b, b->r[rn], rs, 0, &current);
      current += b->active_nonseq16 - b->active_seq16;
      if (!rs) current += thumb_write_pc(b);
      if (!((1u << rn) & rs)) b->r[rn] = address;
    } else {
      uint32_t address = store_multiple(b, b->r[rn], rs, 0, &current);
      current += b->active_nonseq16 - b->active_seq16;
      b->r[rn] = address;
    }
    break;
  }
  case 0x1A: case 0x1B: { /* branches on a condition, and SWI */
    unsigned condition = (opcode >> 8) & 0xFu;
    if (condition == 0xF) {
      arm_raise_swi(b);
    } else if (condition == 0xE) {
      arm_raise_undefined(b);
    } else if (condition_passes(b, condition)) {
      uint32_t offset = sign_extend8(opcode & 0xFFu) << 1;
      b->r[REG_PC] += offset;
      current += thumb_write_pc(b);
    }
    break;
  }
  case 0x1C: { /* B */
    uint32_t offset = (opcode & 0x07FFu) << 1;
    if (offset & 0x800u) offset |= 0xFFFFF000u;
    b->r[REG_PC] += offset;
    current += thumb_write_pc(b);
    break;
  }
  case 0x1D: arm_raise_undefined(b); break;
  case 0x1E: { /* the first half of BL */
    uint32_t offset = (opcode & 0x07FFu) << 12;
    if (offset & 0x00400000u) offset |= 0xFF800000u;
    b->r[REG_LR] = b->r[REG_PC] + offset;
    break;
  }
  default: { /* the second half of BL */
    uint32_t pc = b->r[REG_PC];
    b->r[REG_PC] = b->r[REG_LR] + ((opcode & 0x07FFu) << 1);
    b->r[REG_LR] = pc - 1u;
    current += thumb_write_pc(b);
    break;
  }
  }
  b->cycles += current;
}

static void thumb_step(rg_bios_boot *b) {
  uint32_t opcode = b->prefetch[0];
  b->prefetch[0] = b->prefetch[1];
  b->r[REG_PC] += 2u;
  b->prefetch[1] = fetch(b, b->r[REG_PC], 2);
  thumb_execute(b, opcode & 0xFFFFu);
}

/* ======================================================================================== */
/* EVENTS                                                                                   */
/* ======================================================================================== */

static void on_audio_event(rg_bios_boot *b, uint32_t late);

static void run_event(rg_bios_boot *b, int event, uint32_t late) {
  switch (event) {
  case EVENT_IRQ: on_irq_event(b); break;
  case EVENT_VIDEO:
    if (b->video_next_is_hdraw) start_hdraw(b, late);
    else start_hblank(b, late);
    break;
  case EVENT_AUDIO: on_audio_event(b, late); break;
  case EVENT_TIMER0:
  case EVENT_TIMER1:
  case EVENT_TIMER2:
  case EVENT_TIMER3: timer_overflow(b, event - EVENT_TIMER0, late); break;
  default: on_dma_event(b, late); break;
  }
}

/* ======================================================================================== */
/* RUNNING                                                                                  */
/* ======================================================================================== */

static uint32_t executing_pc(const rg_bios_boot *b) { return b->r[REG_PC] - (b->thumb ? 2u : 4u); }

/* The instructions until the next event is due, then the events. */
static void run_loop(rg_bios_boot *b) {
  while (b->cycles < b->next_event) {
    if (executing_pc(b) == RG_BIOS_BOOT_CARTRIDGE_ENTRY) {
      b->reached_game = 1;
      return;
    }
    if (b->thumb) thumb_step(b);
    else arm_step(b);
  }
  process_events(b);
}

void rg_bios_boot_step(rg_bios_boot *b) {
  while (b->cycles >= b->next_event) process_events(b);
  if (b->thumb) thumb_step(b);
  else arm_step(b);
}

/* How many cycles mGBA lets one frame run before it gives up waiting for the picture to finish. */
#define MOST_CYCLES_A_FRAME (LINES_IN_FRAME * (HDRAW_CYCLES + HBLANK_CYCLES) + HDRAW_CYCLES + HBLANK_CYCLES)

int rg_bios_boot_play_frame(rg_bios_boot *b) {
  if (b->reached_game) return 0;
  long frame = b->frame_counter;
  uint64_t began = now(b);
  b->frame_sound_count = 0;
  while (b->frame_counter == frame && now(b) - began < MOST_CYCLES_A_FRAME) {
    run_loop(b);
    if (b->reached_game) return 0;
  }
  memcpy(b->shown, b->output, sizeof b->shown);
  memcpy(b->sound_shown, b->frame_sound, sizeof(int16_t) * 2u * (size_t)b->frame_sound_count);
  b->sound_shown_count = b->frame_sound_count;
  return 1;
}

static void renderer_reset(rg_bios_boot *b);
static void audio_reset(rg_bios_boot *b);

rg_bios_boot *rg_bios_boot_open(const uint8_t *bios, const uint8_t *cartridge, uint32_t rom_size) {
  rg_bios_boot *b = calloc(1, sizeof *b);
  if (!b) return NULL;
  memcpy(b->bios, bios, SIZE_BIOS);
  memcpy(b->cartridge, cartridge, RG_BIOS_BOOT_CARTRIDGE_BYTES);
  b->rom_size = rom_size;

  for (int i = 0; i < 16; i++) {
    b->waits_nonseq16[i] = BASE_WAITS_NONSEQ16[i];
    b->waits_seq16[i] = BASE_WAITS_SEQ16[i];
    b->waits_nonseq32[i] = BASE_WAITS_NONSEQ32[i];
    b->waits_seq32[i] = BASE_WAITS_SEQ32[i];
  }
  b->active_region = -1;

  /* The processor, as mGBA starts it: in system mode with interrupts let through, at address 0, and
   * each mode's stack where the BIOS expects it. */
  b->privilege_mode = MODE_SYSTEM;
  b->cpsr = MODE_SYSTEM;
  b->thumb = 0;
  arm_write_pc(b);
  b->cycles = 0;
  b->next_event = 0;
  set_privilege_mode(b, MODE_IRQ);
  b->r[REG_SP] = 0x03007FA0u;
  set_privilege_mode(b, MODE_SUPERVISOR);
  b->r[REG_SP] = 0x03007FE0u;
  set_privilege_mode(b, MODE_SYSTEM);
  b->r[REG_SP] = 0x03007F00u;
  b->keys_last = 0x400;
  b->sio_rcnt = 0x8000;
  sio_switch_mode(b);

  adjust_waitstates(b, 0);
  adjust_ewram_waitstates(b, 0x0D00);
  for (int i = 0; i < 4; i++) b->dma[i].count = 0x4000;
  b->dma[3].count = 0x10000;
  b->active_dma = -1;

  b->vcount = 0;
  b->video_next_is_hdraw = 0;
  schedule(b, EVENT_VIDEO, HDRAW_CYCLES);
  audio_reset(b);
  renderer_reset(b);

  b->io[REG_DISPCNT >> 1] = 0x0080;
  b->io[REG_RCNT >> 1] = 0x8000;
  b->io[REG_KEYINPUT >> 1] = 0x3FF;
  b->io[REG_SOUNDBIAS >> 1] = 0x200;
  b->io[REG_BG2PA >> 1] = 0x100;
  b->io[REG_BG2PD >> 1] = 0x100;
  b->io[REG_BG3PA >> 1] = 0x100;
  b->io[REG_BG3PD >> 1] = 0x100;
  b->io[REG_INTERNAL_EXWAITCNT_LO >> 1] = 0x20;
  b->io[REG_INTERNAL_EXWAITCNT_HI >> 1] = 0xD00;
  return b;
}

void rg_bios_boot_close(rg_bios_boot *b) { free(b); }

const uint32_t *rg_bios_boot_picture(const rg_bios_boot *b) { return b->shown; }

int rg_bios_boot_sound(const rg_bios_boot *b, const int16_t **samples) {
  *samples = b->sound_shown;
  return b->sound_shown_count;
}

int rg_bios_boot_sound_rate(const rg_bios_boot *b) { return 16777216 / b->sample_interval; }

long rg_bios_boot_frames(const rg_bios_boot *b) { return b->frame_counter; }

uint32_t rg_bios_boot_register(const rg_bios_boot *b, int n) {
  if (n == 15) return executing_pc(b);
  if (n == 16) return b->cpsr;
  return b->r[n & 15];
}

uint64_t rg_bios_boot_cycles(const rg_bios_boot *b) { return now(b); }

uint8_t rg_bios_boot_peek(const rg_bios_boot *b, uint32_t address) {
  switch (address >> 24) {
  case REGION_BIOS: return address < SIZE_BIOS ? b->bios[address] : 0;
  case REGION_EWRAM: return b->ewram[address & (SIZE_EWRAM - 1u)];
  case REGION_IWRAM: return b->iwram[address & (SIZE_IWRAM - 1u)];
  case REGION_IO: {
    uint32_t at = address & 0xFFFFFFu;
    if (at >= SIZE_IO) return 0;
    return (uint8_t)(b->io[at >> 1] >> ((at & 1u) * 8u));
  }
  case REGION_PALETTE: return b->palette[address & (SIZE_PALETTE - 1u)];
  case REGION_VRAM: return b->vram[vram_offset(address)];
  case REGION_OAM: return b->oam[address & (SIZE_OAM - 1u)];
  default: {
    uint32_t at = address & 0xFFFFFFu;
    return (address >> 24) >= REGION_CART0 && (address >> 24) < REGION_CART_SRAM && at < RG_BIOS_BOOT_CARTRIDGE_BYTES ? b->cartridge[at] : 0;
  }
  }
}

const char *rg_bios_boot_unhandled(const rg_bios_boot *b) { return b->unhandled; }

/* ======================================================================================== */
/* THE PICTURE                                                                              */
/* ======================================================================================== */

/* The picture is drawn a line at a time, as the screen reaches the end of each line, from the
 * registers and memories as they stand then: that is what lets the BIOS turn its background a
 * little differently on every line.
 *
 * A line is composed the way mGBA composes it. Each pixel of the line being built carries, above its
 * 24 bits of colour, a few flags: the priority of what drew it, which background, whether it is a
 * background at all, and whether it is to be blended. The backdrop is put down first with the lowest
 * standing; each layer, front-most priority first, writes a pixel only over something that stands
 * lower, and blends with it where both are blend targets. Sprites are worked out for the whole line
 * first, into a line of their own, and laid over the backgrounds at their priority.
 *
 * The windows cut the line into stretches, each with its own say over which layers show and whether
 * blending happens; the sprite window is a mask the sprites marked as window sprites draw.
 *
 * Only what the start-up uses is drawn: the turning backgrounds (mode 2) and the sprites, which
 * covers mode 1's turning background too. A background in the tiled or bitmap modes, or the mosaic
 * effect, is noted as not handled (rg_bios_boot_unhandled) rather than drawn wrong. */

#define FLAG_PRIORITY 0xC0000000u
#define FLAG_INDEX 0x30000000u
#define FLAG_IS_BACKGROUND 0x08000000u
#define FLAG_UNWRITTEN 0xFC000000u
#define FLAG_REBLEND 0x04000000u
#define FLAG_TARGET_1 0x02000000u
#define FLAG_TARGET_2 0x01000000u
#define FLAG_OBJWIN 0x01000000u
#define FLAG_ORDER_MASK 0xF8000000u
#define OFFSET_PRIORITY 30
#define OFFSET_INDEX 28
#define COLOR_WHITE 0x00FFFFFFu

#define IS_WRITABLE(pixel) ((pixel) & 0xFE000000u)

/* The window control bits: which layers show in a window, and whether it blends. */
#define WIN_BG(packed, n) (((packed) >> (n)) & 1u)
#define WIN_OBJ(packed) (((packed) >> 4) & 1u)
#define WIN_BLEND(packed) (((packed) >> 5) & 1u)

#define DISPCNT_MODE(d) ((d) & 7u)
#define DISPCNT_OBJ_1D(d) (((d) >> 6) & 1u)
#define DISPCNT_FORCED_BLANK(d) (((d) >> 7) & 1u)
#define DISPCNT_OBJ(d) (((d) >> 12) & 1u)
#define DISPCNT_WIN0(d) (((d) >> 13) & 1u)
#define DISPCNT_WIN1(d) (((d) >> 14) & 1u)
#define DISPCNT_OBJWIN(d) (((d) >> 15) & 1u)

static const int OBJ_SIZES[16][2] = {{8, 8},   {16, 16}, {32, 32}, {64, 64}, {16, 8}, {32, 8}, {32, 16}, {64, 32},
                                     {8, 16},  {8, 32},  {16, 32}, {32, 64}, {0, 0},  {0, 0},  {0, 0},   {0, 0}};

/* A colour of the console's (five bits a channel, blue at the top) in eight bits a channel, red at
 * the bottom: each channel's five bits, and its top three again below them. */
static uint32_t color_from_555(uint16_t value) {
  uint32_t color = (uint32_t)(value & 0x1Fu) << 3 | (uint32_t)((value >> 5) & 0x1Fu) << 11 | (uint32_t)((value >> 10) & 0x1Fu) << 19;
  return color | ((color >> 5) & 0x070707u);
}

static uint32_t brighten(uint32_t color, int y) {
  uint32_t c = 0, n = (uint32_t)y;
  uint32_t a = color & 0xFFu;
  c |= (a + ((0xFFu - a) * n) / 16u) & 0xFFu;
  a = color & 0xFF00u;
  c |= (a + ((0xFF00u - a) * n) / 16u) & 0xFF00u;
  a = color & 0xFF0000u;
  c |= (a + ((0xFF0000u - a) * n) / 16u) & 0xFF0000u;
  return c;
}

static uint32_t darken(uint32_t color, int y) {
  uint32_t c = 0, n = (uint32_t)y;
  uint32_t a = color & 0xFFu;
  c |= (a - (a * n) / 16u) & 0xFFu;
  a = color & 0xFF00u;
  c |= (a - (a * n) / 16u) & 0xFF00u;
  a = color & 0xFF0000u;
  c |= (a - (a * n) / 16u) & 0xFF0000u;
  return c;
}

/* Two colours mixed in sixteenths, each channel kept to eight bits. */
static uint32_t mix(int weight_a, uint32_t color_a, int weight_b, uint32_t color_b) {
  uint32_t wa = (uint32_t)weight_a, wb = (uint32_t)weight_b, c = 0;
  uint32_t a = color_a & 0xFFu, bb = color_b & 0xFFu;
  c |= ((a * wa + bb * wb) / 16u) & 0x1FFu;
  if (c & 0x100u) c = 0xFFu;
  a = color_a & 0xFF00u;
  bb = color_b & 0xFF00u;
  c |= ((a * wa + bb * wb) / 16u) & 0x1FF00u;
  if (c & 0x10000u) c = (c & 0xFFu) | 0xFF00u;
  a = color_a & 0xFF0000u;
  bb = color_b & 0xFF0000u;
  c |= ((a * wa + bb * wb) / 16u) & 0x1FF0000u;
  if (c & 0x1000000u) c = (c & 0xFFFFu) | 0xFF0000u;
  return c;
}

static void update_palettes(rg_bios_boot *b) {
  for (int i = 0; i < 512; i++) {
    if (b->blend_effect == BLEND_BRIGHTEN) b->variant_palette[i] = brighten(b->normal_palette[i], b->bldy);
    else if (b->blend_effect == BLEND_DARKEN) b->variant_palette[i] = darken(b->normal_palette[i], b->bldy);
    else b->variant_palette[i] = b->normal_palette[i];
  }
}

/* Each background's flags for the window stretch being drawn. */
static void update_flags(rg_bios_boot *b, boot_background *bg) {
  uint32_t flags = bg->priority << OFFSET_PRIORITY | (uint32_t)bg->index << OFFSET_INDEX | FLAG_IS_BACKGROUND;
  if (bg->target2) flags |= FLAG_TARGET_2;
  uint32_t objwin_flags = flags;
  if (b->blend_effect == BLEND_ALPHA) {
    if (b->blda == 0x10 && b->bldb == 0) {
      flags &= ~FLAG_TARGET_2;
      objwin_flags &= ~FLAG_TARGET_2;
    } else if (bg->target1) {
      if (WIN_BLEND(b->current_window.packed)) flags |= FLAG_TARGET_1;
      if (WIN_BLEND(b->objwin.packed)) objwin_flags |= FLAG_TARGET_1;
    }
  }
  bg->flags = flags;
  bg->objwin_flags = objwin_flags;
  bg->variant = bg->target1 && WIN_BLEND(b->current_window.packed) &&
                (b->blend_effect == BLEND_BRIGHTEN || b->blend_effect == BLEND_DARKEN);
}

/* A background switched on shows from a few lines later, except between frames. */
static void enable_bg(rg_bios_boot *b, int index, int active) {
  boot_background *bg = &b->bg[index];
  int was_active = bg->enabled;
  if (!active) {
    if (b->next_y == 0 || (was_active > 0 && was_active < BG_ENABLED_MAX)) bg->enabled = 0;
    else if (was_active == BG_ENABLED_MAX) bg->enabled = -2;
  } else if (!was_active) {
    if (b->next_y == 0) bg->enabled = BG_ENABLED_MAX;
    else if (DISPCNT_MODE(b->dispcnt) > 2) bg->enabled = 2;
    else bg->enabled = 1;
  } else if (was_active < 0) {
    bg->enabled = BG_ENABLED_MAX;
  }
}

static void update_dispcnt(rg_bios_boot *b) {
  for (int i = 0; i < 4; i++) enable_bg(b, i, (int)((b->dispcnt >> (8 + i)) & 1u));
}

static void write_bgcnt(rg_bios_boot *b, boot_background *bg, uint16_t value) {
  bg->priority = value & 3u;
  bg->char_base = (uint32_t)((value >> 2) & 3u) << 14;
  bg->mosaic = (value >> 6) & 1;
  bg->multipalette = (value >> 7) & 1;
  bg->screen_base = (uint32_t)((value >> 8) & 0x1Fu) << 11;
  bg->overflow = (value >> 13) & 1;
  bg->size = (value >> 14) & 3;
  update_flags(b, bg);
}

static void write_bldcnt(rg_bios_boot *b, uint16_t value) {
  int old_effect = b->blend_effect;
  for (int i = 0; i < 4; i++) {
    b->bg[i].target1 = (value >> i) & 1;
    b->bg[i].target2 = (value >> (8 + i)) & 1;
  }
  b->blend_effect = (value >> 6) & 3;
  b->target1_obj = (value >> 4) & 1;
  b->target1_bd = (value >> 5) & 1;
  b->target2_obj = (value >> 12) & 1;
  b->target2_bd = (value >> 13) & 1;
  if (old_effect != b->blend_effect) b->blend_dirty = 1;
}

/* A window's edges, kept within the screen the way mGBA keeps them. */
static void write_window_edges(int *start, int *end, uint16_t value, int limit) {
  *end = value & 0xFF;
  *start = value >> 8;
  if (*start > limit && *start > *end) *start = 0;
  if (*end > limit) {
    *end = limit;
    if (*start > limit) *start = limit;
  }
}

static int32_t sign_extend28(uint32_t value) {
  value &= 0x0FFFFFFFu;
  return (int32_t)((value & 0x08000000u) ? value | 0xF0000000u : value);
}

static uint16_t renderer_write_register(rg_bios_boot *b, uint32_t address, uint16_t value) {
  boot_background *bg2 = &b->bg[2], *bg3 = &b->bg[3];
  switch (address) {
  case REG_DISPCNT:
    value &= 0xFFF7u;
    b->dispcnt = value;
    update_dispcnt(b);
    break;
  case REG_GREENSWP:
    if (value & 1u) note_unhandled(b, "green swap", 0x04000002u);
    break;
  case 0x008:
  case 0x00A:
    value &= 0xDFFFu;
    write_bgcnt(b, &b->bg[(address - 0x008u) >> 1], value);
    break;
  case 0x00C:
  case 0x00E: write_bgcnt(b, &b->bg[(address - 0x008u) >> 1], value); break;
  case 0x010: case 0x012: case 0x014: case 0x016: case 0x018: case 0x01A: case 0x01C: case 0x01E:
    value &= 0x01FFu;
    break;
  case REG_BG2PA: bg2->dx = (int16_t)value; break;
  case REG_BG2PB: bg2->dmx = (int16_t)value; break;
  case REG_BG2PC: bg2->dy = (int16_t)value; break;
  case REG_BG2PD: bg2->dmy = (int16_t)value; break;
  case REG_BG2X_LO: bg2->refx = (int32_t)(((uint32_t)bg2->refx & 0xFFFF0000u) | value); bg2->sx = bg2->refx; break;
  case REG_BG2X_HI: bg2->refx = sign_extend28(((uint32_t)bg2->refx & 0xFFFFu) | (uint32_t)value << 16); bg2->sx = bg2->refx; break;
  case REG_BG2Y_LO: bg2->refy = (int32_t)(((uint32_t)bg2->refy & 0xFFFF0000u) | value); bg2->sy = bg2->refy; break;
  case REG_BG2Y_HI: bg2->refy = sign_extend28(((uint32_t)bg2->refy & 0xFFFFu) | (uint32_t)value << 16); bg2->sy = bg2->refy; break;
  case REG_BG3PA: bg3->dx = (int16_t)value; break;
  case REG_BG3PB: bg3->dmx = (int16_t)value; break;
  case REG_BG3PC: bg3->dy = (int16_t)value; break;
  case REG_BG3PD: bg3->dmy = (int16_t)value; break;
  case REG_BG3X_LO: bg3->refx = (int32_t)(((uint32_t)bg3->refx & 0xFFFF0000u) | value); bg3->sx = bg3->refx; break;
  case REG_BG3X_HI: bg3->refx = sign_extend28(((uint32_t)bg3->refx & 0xFFFFu) | (uint32_t)value << 16); bg3->sx = bg3->refx; break;
  case REG_BG3Y_LO: bg3->refy = (int32_t)(((uint32_t)bg3->refy & 0xFFFF0000u) | value); bg3->sy = bg3->refy; break;
  case REG_BG3Y_HI: bg3->refy = sign_extend28(((uint32_t)bg3->refy & 0xFFFFu) | (uint32_t)value << 16); bg3->sy = bg3->refy; break;
  case REG_BLDCNT:
    write_bldcnt(b, value);
    value &= 0x3FFFu;
    break;
  case REG_BLDALPHA:
    b->blda = value & 0x1F;
    if (b->blda > 0x10) b->blda = 0x10;
    b->bldb = (value >> 8) & 0x1F;
    if (b->bldb > 0x10) b->bldb = 0x10;
    value &= 0x1F1Fu;
    break;
  case REG_BLDY:
    value &= 0x1Fu;
    if (value > 0x10) value = 0x10;
    if (b->bldy != value) {
      b->bldy = value;
      b->blend_dirty = 1;
    }
    break;
  case REG_WIN0H: write_window_edges(&b->win_n[0].h.start, &b->win_n[0].h.end, value, RG_BIOS_BOOT_WIDTH); break;
  case REG_WIN1H: write_window_edges(&b->win_n[1].h.start, &b->win_n[1].h.end, value, RG_BIOS_BOOT_WIDTH); break;
  case REG_WIN0V: write_window_edges(&b->win_n[0].v.start, &b->win_n[0].v.end, value, RG_BIOS_BOOT_HEIGHT); break;
  case REG_WIN1V: write_window_edges(&b->win_n[1].v.start, &b->win_n[1].v.end, value, RG_BIOS_BOOT_HEIGHT); break;
  case REG_WININ:
    value &= 0x3F3Fu;
    b->win_n[0].control.packed = (uint8_t)value;
    b->win_n[1].control.packed = (uint8_t)(value >> 8);
    break;
  case REG_WINOUT:
    value &= 0x3F3Fu;
    b->winout.packed = (uint8_t)value;
    b->objwin.packed = (uint8_t)(value >> 8);
    break;
  case REG_MOSAIC: b->mosaic = value; break;
  default: break;
  }
  return value;
}

static void renderer_write_oam(rg_bios_boot *b) { b->oam_dirty = 1; }

static void renderer_write_palette(rg_bios_boot *b, uint32_t address, uint16_t value) {
  uint32_t color = color_from_555(value);
  b->normal_palette[address >> 1] = color;
  if (b->blend_effect == BLEND_BRIGHTEN) b->variant_palette[address >> 1] = brighten(color, b->bldy);
  else if (b->blend_effect == BLEND_DARKEN) b->variant_palette[address >> 1] = darken(color, b->bldy);
}

static void renderer_reset(rg_bios_boot *b) {
  b->dispcnt = 0x0080;
  b->blend_effect = BLEND_NONE;
  for (int i = 0; i < 512; i++) b->normal_palette[i] = color_from_555(load_le16(b->palette + 2 * i));
  update_palettes(b);
  b->win_n[0].control.priority = 0;
  b->win_n[1].control.priority = 1;
  b->objwin.priority = 2;
  b->winout.priority = 3;
  b->oam_dirty = 1;
  for (int i = 0; i < 4; i++) {
    memset(&b->bg[i], 0, sizeof b->bg[i]);
    b->bg[i].index = i;
    b->bg[i].dx = 256;
    b->bg[i].dmy = 256;
  }
  for (size_t i = 0; i < sizeof b->output / sizeof b->output[0]; i++) b->output[i] = COLOR_WHITE;
}

/* --- the windows: the line cut into stretches, each with the window over it --- */

static void break_window_inner(rg_bios_boot *b, const boot_window_n *win) {
  int start_x = 0;
  if (win->h.end <= 0) return;
  for (int active = 0; active < b->n_windows; ++active) {
    if (win->h.start < b->windows[active].end_x) {
      boot_window old = b->windows[active];
      if (win->h.start > start_x) {
        if (b->n_windows >= MOST_WINDOWS) return;
        for (int next = b->n_windows++; next > active; --next) b->windows[next] = b->windows[next - 1];
        b->windows[active].end_x = win->h.start;
        ++active;
      }
      b->windows[active].control = win->control;
      b->windows[active].end_x = win->h.end;
      if (win->h.end >= old.end_x) {
        for (++active; b->n_windows > active + 1 && win->h.end >= b->windows[active].end_x; ++active) {
          b->windows[active] = b->windows[active + 1];
          --b->n_windows;
        }
      } else {
        ++active;
        if (b->n_windows >= MOST_WINDOWS) return;
        for (int next = b->n_windows++; next > active; --next) b->windows[next] = b->windows[next - 1];
        b->windows[active] = old;
      }
      return;
    }
    start_x = b->windows[active].end_x;
  }
}

static void break_window(rg_bios_boot *b, const boot_window_n *win, int y) {
  if (win->v.end >= win->v.start) {
    if (y >= win->v.end || y < win->v.start) return;
  } else if (y >= win->v.end && y < win->v.start) {
    return;
  }
  if (win->h.end > RG_BIOS_BOOT_WIDTH || win->h.end < win->h.start) {
    boot_window_n left = *win, right = *win;
    left.h.start = 0;
    right.h.end = RG_BIOS_BOOT_WIDTH;
    break_window_inner(b, &left);
    break_window_inner(b, &right);
  } else {
    break_window_inner(b, win);
  }
}

/* --- sprites --- */

static int clean_oam(rg_bios_boot *b) {
  int most = 0;
  for (int i = 0; i < 128; i++) {
    uint16_t a = load_le16(b->oam + 8 * i), bb = load_le16(b->oam + 8 * i + 2), c = load_le16(b->oam + 8 * i + 4);
    int transformed = (a >> 8) & 1, disable = (a >> 9) & 1;
    if (!transformed && disable) continue;
    int shape_size = ((a >> 14) & 3) * 4 + ((bb >> 14) & 3);
    int width = OBJ_SIZES[shape_size][0], height = OBJ_SIZES[shape_size][1];
    int cycles = width;
    if (transformed) {
      height <<= disable;
      width <<= disable;
      cycles = 10 + width * 2;
    }
    int y = a & 0xFF, x = bb & 0x1FF;
    if (y >= LINES_DRAWN && y + height < LINES_IN_FRAME) continue;
    if (x >= RG_BIOS_BOOT_WIDTH && x + width < 512) continue;
    b->sprites[most] = (boot_sprite){y, y + height, cycles, i, a, bb, c};
    ++most;
  }
  return most;
}

/* A pixel of a sprite onto the sprites' own line, if it stands higher than what is there. */
static void put_sprite_pixel(rg_bios_boot *b, int out_x, uint32_t color_index, const uint32_t *palette,
                             const uint32_t *objwin_palette, uint32_t flags, int kind) {
  if (kind == 2) { /* a window sprite marks the window, and draws nothing */
    if (color_index) b->row[out_x] |= FLAG_OBJWIN;
    return;
  }
  uint32_t current = b->sprite_layer[out_x];
  if ((current & FLAG_ORDER_MASK) > flags) {
    if (color_index) {
      uint32_t color = kind == 1 && (b->row[out_x] & FLAG_OBJWIN) ? objwin_palette[color_index] : palette[color_index];
      b->sprite_layer[out_x] = color | flags;
    } else if (current != FLAG_UNWRITTEN) {
      uint32_t kept = FLAG_ORDER_MASK | FLAG_REBLEND | FLAG_TARGET_1;
      b->sprite_layer[out_x] = (current & ~kept) | (flags & kept);
    }
  }
}

/* The colour index of a sprite's pixel (+local_x+, +local_y+ inside it). */
static uint32_t sprite_texel(const rg_bios_boot *b, int local_x, int local_y, int is256, uint32_t stride, uint32_t char_base,
                             uint32_t mask_lo, uint32_t mask_hi) {
  uint32_t lx = (uint32_t)local_x, ly = (uint32_t)local_y, x_base, y_base;
  if (is256) {
    x_base = (lx & ~7u) * 8u + (lx & 6u);
    y_base = (ly & ~7u) * stride + (ly & 7u) * 8u + mask_hi;
  } else {
    x_base = (lx & ~7u) * 4u + ((lx >> 1) & 2u);
    y_base = (ly & ~7u) * stride + (ly & 7u) * 4u + mask_hi;
  }
  uint32_t at = (y_base + ((x_base + char_base) & mask_lo)) & 0x7FFEu;
  uint32_t data = load_le16(b->vram + 0x10000u + at);
  return is256 ? (data >> ((lx & 1u) << 3)) & 0xFFu : (data >> ((lx & 3u) << 2)) & 0xFu;
}

static int preprocess_sprite(rg_bios_boot *b, const boot_sprite *sprite, int y) {
  uint16_t a = sprite->a, bb = sprite->b, c = sprite->c;
  int shape_size = ((a >> 14) & 3) * 4 + ((bb >> 14) & 3);
  int width = OBJ_SIZES[shape_size][0], height = OBJ_SIZES[shape_size][1];
  int start = b->start, end = b->end;
  unsigned mode = (a >> 10) & 3u;
  int is256 = (a >> 13) & 1, one_d = (int)DISPCNT_OBJ_1D(b->dispcnt);
  uint32_t flags = (uint32_t)((c >> 10) & 3u) << OFFSET_PRIORITY;
  if ((WIN_BLEND(b->current_window.packed) && b->target1_obj && b->blend_effect == BLEND_ALPHA) || mode == 1) flags |= FLAG_TARGET_1;
  if (mode == 2) flags |= FLAG_OBJWIN;
  if ((flags & FLAG_OBJWIN) && b->current_window.priority < b->objwin.priority) return 0;
  if ((a >> 12) & 1) {
    if (b->mosaic) note_unhandled(b, "sprite mosaic", 0x0400004Cu);
  }
  int x = (int)(bb & 0x1FFu);
  if (x & 0x100) x -= 0x200;
  uint32_t tile = c & 0x3FFu;
  uint32_t align = (uint32_t)(is256 && !one_d);
  uint32_t char_base = (tile & ~align) * 0x20u;
  uint32_t mask_lo = one_d ? 0x7FFEu : 0x3FEu;
  uint32_t mask_hi = one_d ? 0u : char_base & 0x7C00u;
  if (DISPCNT_MODE(b->dispcnt) >= 3 && tile < 512) return 0;

  int objwin_slow_path = DISPCNT_OBJWIN(b->dispcnt) && WIN_BLEND(b->objwin.packed) != WIN_BLEND(b->current_window.packed);
  int variant = b->target1_obj && WIN_BLEND(b->current_window.packed) &&
                (b->blend_effect == BLEND_BRIGHTEN || b->blend_effect == BLEND_DARKEN);
  if (mode == 1 || (b->target1_obj && b->blend_effect == BLEND_ALPHA) || objwin_slow_path) {
    int target2 = b->target2_bd;
    for (int i = 0; i < 4; i++) target2 |= b->bg[i].target2 && b->bg[i].enabled;
    if (target2) {
      b->force_target1 = 1;
      flags |= FLAG_REBLEND;
      variant = 0;
    } else {
      flags &= ~FLAG_TARGET_1;
    }
  }
  const uint32_t *palette = &b->normal_palette[0x100];
  const uint32_t *objwin_palette = palette;
  if (variant) {
    palette = &b->variant_palette[0x100];
    if (WIN_BLEND(b->objwin.packed)) objwin_palette = palette;
  }
  int kind = (flags & FLAG_OBJWIN) ? 2 : objwin_slow_path ? 1 : 0;
  int in_y = y - (int)(a & 0xFFu);
  uint32_t stride = one_d ? (uint32_t)(width >> !is256) : 0x80u;
  if (!is256) {
    palette += ((c >> 12) & 0xFu) << 4;
    objwin_palette += ((c >> 12) & 0xFu) << 4;
  }

  if ((a >> 8) & 1) { /* a turned sprite */
    int doubled = (a >> 9) & 1;
    int total_width = width << doubled, total_height = height << doubled;
    uint32_t matrix = ((bb >> 9) & 0x1Fu) * 32u;
    int ma = (int16_t)load_le16(b->oam + matrix + 6), mb = (int16_t)load_le16(b->oam + matrix + 14);
    int mc = (int16_t)load_le16(b->oam + matrix + 22), md = (int16_t)load_le16(b->oam + matrix + 30);
    if (in_y < 0) in_y += 256;
    int out_x = x >= start ? x : start;
    int condition = x + total_width;
    int in_x = out_x - x;
    if (end < condition) condition = end;
    int x_accum = ma * (in_x - 1 - (total_width >> 1)) + mb * (in_y - (total_height >> 1)) + (width << 7);
    int y_accum = mc * (in_x - 1 - (total_width >> 1)) + md * (in_y - (total_height >> 1)) + (height << 7);
    /* Pixels at the left that fall outside the sprite's picture are skipped in one go. */
    if (ma) {
      if ((x_accum >> 8) < 0) {
        int skip = (-x_accum - 1) / ma;
        x_accum += ma * skip;
        y_accum += mc * skip;
        out_x += skip;
        in_x += skip;
      } else if ((x_accum >> 8) >= width) {
        int skip = ((width << 8) - x_accum) / ma;
        x_accum += ma * skip;
        y_accum += mc * skip;
        out_x += skip;
        in_x += skip;
      }
    }
    if (mc) {
      if ((y_accum >> 8) < 0) {
        int skip = (-y_accum - 1) / mc;
        x_accum += ma * skip;
        y_accum += mc * skip;
        out_x += skip;
        in_x += skip;
      } else if ((y_accum >> 8) >= height) {
        int skip = ((height << 8) - y_accum) / mc;
        x_accum += ma * skip;
        y_accum += mc * skip;
        out_x += skip;
        in_x += skip;
      }
    }
    if (out_x < start || out_x >= condition) return 0;
    for (; out_x < condition; ++out_x, ++in_x) {
      x_accum += ma;
      y_accum += mc;
      int local_x = x_accum >> 8, local_y = y_accum >> 8;
      if ((local_x & ~(width - 1)) || (local_y & ~(height - 1))) break;
      uint32_t texel = sprite_texel(b, local_x, local_y, is256, stride, char_base, mask_lo, mask_hi);
      put_sprite_pixel(b, out_x, texel, palette, objwin_palette, flags, kind);
    }
  } else {
    int out_x = x >= start ? x : start;
    int condition = x + width;
    if ((int)(a & 0xFFu) + height - 256 >= 0) in_y += 256;
    if ((bb >> 13) & 1) in_y = height - in_y - 1;
    if (end < condition) condition = end;
    int in_x = out_x - x, step = 1;
    if ((bb >> 12) & 1) {
      in_x = width - in_x - 1;
      step = -1;
    }
    for (; out_x < condition; ++out_x, in_x += step) {
      uint32_t texel = sprite_texel(b, in_x, in_y, is256, stride, char_base, mask_lo, mask_hi);
      put_sprite_pixel(b, out_x, texel, palette, objwin_palette, flags, kind);
    }
  }
  return 1;
}

static int preprocess_sprite_layer(rg_bios_boot *b, int y) {
  int layers = 0;
  if (!DISPCNT_OBJ(b->dispcnt)) return 0;
  if (b->oam_dirty) {
    b->oam_max = clean_oam(b);
    b->oam_dirty = 0;
  }
  for (int i = 0; i < b->oam_max; i++) {
    const boot_sprite *sprite = &b->sprites[i];
    b->end = 0;
    if ((y < sprite->y && (sprite->end_y - 256 < 0 || y >= sprite->end_y - 256)) || y >= sprite->end_y) continue;
    for (int w = 0; w < b->n_windows; w++) {
      b->current_window = b->windows[w].control;
      b->start = b->end;
      b->end = b->windows[w].end_x;
      if (!WIN_OBJ(b->current_window.packed) && !DISPCNT_OBJWIN(b->dispcnt)) continue;
      int drawn = preprocess_sprite(b, sprite, y);
      layers |= drawn << ((sprite->c >> 10) & 3u);
    }
    b->sprite_cycles_remaining -= sprite->cycles;
    if (b->sprite_cycles_remaining <= 0) break;
  }
  return layers;
}

/* --- putting the layers together --- */

static void composite(rg_bios_boot *b, uint32_t *pixel, uint32_t color, uint32_t current, int blend, int objwin) {
  if (blend) {
    if (color >= current) {
      if ((current & FLAG_TARGET_1) && (color & FLAG_TARGET_2)) color = mix(b->blda, current, b->bldb, color);
      else color = current & (0x00FFFFFFu | FLAG_REBLEND | FLAG_OBJWIN);
    } else {
      color = objwin ? (color & ~FLAG_TARGET_2) | (current & FLAG_OBJWIN) : color & ~FLAG_TARGET_2;
    }
  } else if (objwin) {
    if (color < current) color |= current & FLAG_OBJWIN;
    else color = current & (0x00FFFFFFu | FLAG_REBLEND | FLAG_OBJWIN);
  } else if (color >= current) {
    color = current & (0x00FFFFFFu | FLAG_REBLEND | FLAG_OBJWIN);
  }
  *pixel = color;
}

static void postprocess_sprite(rg_bios_boot *b, unsigned priority) {
  uint32_t flags = b->target2_obj ? FLAG_TARGET_2 : 0u;
  int objwin_slow_path = (int)DISPCNT_OBJWIN(b->dispcnt);
  int objwin_disable = 0, objwin_only = 0;
  if (objwin_slow_path) {
    objwin_disable = !WIN_OBJ(b->objwin.packed);
    objwin_only = !objwin_disable && !WIN_OBJ(b->current_window.packed);
    if (objwin_disable && !WIN_OBJ(b->current_window.packed)) return;
  } else if (!WIN_OBJ(b->current_window.packed)) {
    return;
  }
  for (int x = b->start; x < b->end; ++x) {
    uint32_t color = b->sprite_layer[x] & ~FLAG_OBJWIN;
    uint32_t current = b->row[x];
    if ((color & FLAG_UNWRITTEN) == FLAG_UNWRITTEN || (color & FLAG_PRIORITY) >> OFFSET_PRIORITY != priority) continue;
    if (objwin_slow_path) {
      if (objwin_disable && (current & FLAG_OBJWIN)) continue;
      if (objwin_only && !(current & FLAG_OBJWIN)) continue;
    }
    composite(b, &b->row[x], color | flags, current, 1, objwin_slow_path);
  }
}

/* A turning background's stretch of the line: each pixel steps through the background's map by the
 * turn's matrix, from where the line starts. */
static void draw_background_mode2(rg_bios_boot *b, boot_background *bg) {
  int32_t size_adjusted = 0x8000 << bg->size;
  int32_t x = bg->sx + (b->start - 1) * bg->dx;
  int32_t y = bg->sy + (b->start - 1) * bg->dy;
  if (bg->mosaic && b->mosaic) note_unhandled(b, "background mosaic", 0x0400004Cu);
  uint32_t flags = bg->flags, objwin_flags = bg->objwin_flags;
  const uint32_t *palette = bg->variant ? b->variant_palette : b->normal_palette;
  int objwin_slow_path = (int)DISPCNT_OBJWIN(b->dispcnt);
  int objwin_only = 0, objwin_force_enable = 0;
  const uint32_t *objwin_palette = b->normal_palette;
  if (objwin_slow_path) {
    if (bg->target1 && WIN_BLEND(b->objwin.packed) && (b->blend_effect == BLEND_BRIGHTEN || b->blend_effect == BLEND_DARKEN))
      objwin_palette = b->variant_palette;
    objwin_force_enable = WIN_BG(b->objwin.packed, bg->index) && WIN_BG(b->current_window.packed, bg->index);
    objwin_only = !WIN_BG(b->objwin.packed, bg->index);
  }
  int blend = (flags & FLAG_TARGET_2) != 0;
  const uint8_t *screen = b->vram + bg->screen_base, *chars = b->vram + bg->char_base;
  for (int out_x = b->start; out_x < b->end; ++out_x) {
    x += bg->dx;
    y += bg->dy;
    uint32_t current = b->row[out_x];
    int32_t local_x, local_y;
    if (bg->overflow) {
      local_x = x & (size_adjusted - 1);
      local_y = y & (size_adjusted - 1);
    } else {
      if ((x | y) & ~(size_adjusted - 1)) continue;
      local_x = x;
      local_y = y;
    }
    uint32_t map = screen[(local_x >> 11) + (((local_y >> 7) & 0x7F0) << bg->size)];
    uint32_t pixel = chars[(map << 6) + (uint32_t)((local_y & 0x700) >> 5) + (uint32_t)((local_x & 0x700) >> 8)];
    if (!pixel || !IS_WRITABLE(current)) continue;
    if (!objwin_slow_path) {
      composite(b, &b->row[out_x], palette[pixel] | flags, current, blend, 0);
    } else if (objwin_force_enable || (!(current & FLAG_OBJWIN)) == objwin_only) {
      uint32_t color = (current & FLAG_OBJWIN) ? objwin_palette[pixel] : palette[pixel];
      uint32_t merged = (current & FLAG_OBJWIN) ? objwin_flags : flags;
      composite(b, &b->row[out_x], color | merged, current, blend, 1);
    }
  }
}

static void preprocess_buffer(rg_bios_boot *b, int y) {
  for (int x = 0; x < RG_BIOS_BOOT_WIDTH; x++) b->sprite_layer[x] = FLAG_UNWRITTEN;
  b->windows[0].end_x = RG_BIOS_BOOT_WIDTH;
  b->n_windows = 1;
  if (DISPCNT_WIN0(b->dispcnt) || DISPCNT_WIN1(b->dispcnt) || DISPCNT_OBJWIN(b->dispcnt)) {
    b->windows[0].control = b->winout;
    if (DISPCNT_WIN1(b->dispcnt)) break_window(b, &b->win_n[1], y);
    if (DISPCNT_WIN0(b->dispcnt)) break_window(b, &b->win_n[0], y);
  } else {
    b->windows[0].control.packed = 0xFF;
  }
  update_dispcnt(b);
  if (b->blend_dirty) {
    update_palettes(b);
    b->blend_dirty = 0;
  }
  b->force_target1 = 0;
  int x = 0;
  for (int w = 0; w < b->n_windows; w++) {
    uint32_t backdrop = FLAG_UNWRITTEN | FLAG_PRIORITY | FLAG_IS_BACKGROUND;
    if (!b->target1_bd || b->blend_effect == BLEND_NONE || b->blend_effect == BLEND_ALPHA || !WIN_BLEND(b->windows[w].control.packed))
      backdrop |= b->normal_palette[0];
    else backdrop |= b->variant_palette[0];
    for (; x < b->windows[w].end_x; ++x) b->row[x] = backdrop;
  }
}

static void postprocess_buffer(rg_bios_boot *b) {
  if ((b->force_target1 || b->bg[0].target1 || b->bg[1].target1 || b->bg[2].target1 || b->bg[3].target1) && b->target2_bd) {
    int x = 0;
    for (int w = 0; w < b->n_windows; w++) {
      uint32_t backdrop;
      if (!b->target1_bd || b->blend_effect == BLEND_NONE || b->blend_effect == BLEND_ALPHA || !WIN_BLEND(b->windows[w].control.packed))
        backdrop = b->normal_palette[0];
      else backdrop = b->variant_palette[0];
      for (; x < b->windows[w].end_x; ++x) {
        uint32_t color = b->row[x];
        if (color & FLAG_TARGET_1) b->row[x] = mix(b->bldb, backdrop, b->blda, color);
      }
    }
  }
  if (b->force_target1 && (b->blend_effect == BLEND_DARKEN || b->blend_effect == BLEND_BRIGHTEN)) {
    int x = 0;
    for (int w = 0; w < b->n_windows; w++) {
      int end = b->windows[w].end_x;
      uint32_t mask = FLAG_REBLEND | FLAG_IS_BACKGROUND, match = FLAG_REBLEND;
      int objwin_blend = (int)WIN_BLEND(b->objwin.packed), window_blend = (int)WIN_BLEND(b->windows[w].control.packed);
      if (DISPCNT_OBJWIN(b->dispcnt) && objwin_blend != window_blend) {
        mask |= FLAG_OBJWIN;
        if (objwin_blend) match |= FLAG_OBJWIN;
      } else if (!window_blend) {
        x = end;
        continue;
      }
      for (; x < end; ++x) {
        uint32_t color = b->row[x];
        if ((color & mask) != match) continue;
        b->row[x] = b->blend_effect == BLEND_DARKEN ? darken(color, b->bldy) : brighten(color, b->bldy);
      }
    }
  }
}

static int layer_shown(const rg_bios_boot *b, int index, unsigned priority) {
  const boot_background *bg = &b->bg[index];
  return bg->enabled == BG_ENABLED_MAX &&
         (WIN_BG(b->current_window.packed, index) || (DISPCNT_OBJWIN(b->dispcnt) && WIN_BG(b->objwin.packed, index))) &&
         bg->priority == priority;
}

static void renderer_draw_scanline(rg_bios_boot *b, int y) {
  b->next_y = y == RG_BIOS_BOOT_HEIGHT - 1 ? 0 : y + 1;
  uint32_t *out = &b->output[RG_BIOS_BOOT_WIDTH * y];
  if (DISPCNT_FORCED_BLANK(b->dispcnt)) {
    for (int x = 0; x < RG_BIOS_BOOT_WIDTH; x++) out[x] = COLOR_WHITE;
    return;
  }
  preprocess_buffer(b, y);
  b->sprite_cycles_remaining = (b->dispcnt >> 5) & 1u ? 954 : 1210;
  int sprite_layers = preprocess_sprite_layer(b, y);
  unsigned mode = DISPCNT_MODE(b->dispcnt);
  b->end = 0;
  for (int w = 0; w < b->n_windows; w++) {
    b->start = b->end;
    b->end = b->windows[w].end_x;
    b->current_window = b->windows[w].control;
    switch (mode) {
    case 0:
      for (int i = 0; i < 2; i++)
        if (b->bg[i].enabled == BG_ENABLED_MAX) update_flags(b, &b->bg[i]);
      /* fall through */
    case 2:
      if (b->bg[3].enabled == BG_ENABLED_MAX) update_flags(b, &b->bg[3]);
      /* fall through */
    case 3:
    case 4:
    case 5:
      if (b->bg[2].enabled == BG_ENABLED_MAX) update_flags(b, &b->bg[2]);
      break;
    case 1:
      for (int i = 0; i < 3; i++)
        if (b->bg[i].enabled == BG_ENABLED_MAX) update_flags(b, &b->bg[i]);
      break;
    default: break;
    }
    for (unsigned priority = 0; priority < 4; priority++) {
      if (sprite_layers & (1 << priority)) postprocess_sprite(b, priority);
      for (int i = 0; i < 2; i++)
        if (layer_shown(b, i, priority) && mode < 2) note_unhandled(b, "a tiled background", 0x04000008u + 2u * (uint32_t)i);
      if (layer_shown(b, 2, priority)) {
        if (mode == 1 || mode == 2) draw_background_mode2(b, &b->bg[2]);
        else note_unhandled(b, mode == 0 ? "a tiled background" : "a bitmap screen", 0x0400000Cu);
      }
      if (layer_shown(b, 3, priority)) {
        if (mode == 2) draw_background_mode2(b, &b->bg[3]);
        else if (mode == 0) note_unhandled(b, "a tiled background", 0x0400000Eu);
      }
    }
  }
  postprocess_buffer(b);
  if (mode != 0) {
    for (int i = 2; i < 4; i++) {
      if (b->bg[i].enabled != BG_ENABLED_MAX) continue;
      b->bg[i].sx += b->bg[i].dmx;
      b->bg[i].sy += b->bg[i].dmy;
    }
  }
  for (int i = 0; i < 4; i++)
    if (b->bg[i].enabled != 0 && b->bg[i].enabled < BG_ENABLED_MAX) ++b->bg[i].enabled;
  for (int x = 0; x < RG_BIOS_BOOT_WIDTH; x++) out[x] = b->row[x] & 0x00FFFFFFu;
}

static void renderer_finish_frame(rg_bios_boot *b) {
  b->next_y = 0;
  for (int i = 2; i < 4; i++) {
    b->bg[i].sx = b->bg[i].refx;
    b->bg[i].sy = b->bg[i].refy;
  }
  for (int i = 0; i < 4; i++)
    if (b->bg[i].enabled > 0) b->bg[i].enabled = BG_ENABLED_MAX;
}

/* ======================================================================================== */
/* THE SOUND                                                                                */
/* ======================================================================================== */

/* THE CHIME is recorded sound: the BIOS mixes it itself, into a stretch of memory, and two of the
 * copy engines feed it a word at a time to the two recorded-sound voices' queues (A and B), each time
 * a timer runs out and its queue has room. Each time the timer runs out the voice moves to its next
 * 8-bit sample.
 *
 * What the speaker hears is mixed every 1,024 cycles (SAMPLE_TICK_CYCLES), as mGBA mixes it: that
 * stretch is cut into 2, 4, 8 or 16 samples (two, unless SOUNDBIAS asks for more), each the sum of
 * the voices' samples at that moment, scaled by their volumes, offset by the bias and kept within
 * the ten bits the console's output has. Those samples are the frame's sound. The tone voices are
 * left out: the start-up never plays them (a test holds rg_bios_boot_unhandled to that). */

#define SAMPLE_TICK_CYCLES 1024
#define MASTER_VOLUME 0x100

static unsigned bias_resolution(uint16_t soundbias) { return (soundbias >> 14) & 3u; }

static void audio_reset(rg_bios_boot *b) {
  schedule(b, EVENT_AUDIO, 0);
  b->fifo[0].dma_source = 1;
  b->fifo[1].dma_source = 2;
  b->soundbias = 0x200;
  b->sample_interval = 16777216 / 0x8000;
}

static int16_t apply_bias(const rg_bios_boot *b, int sample) {
  int bias = b->soundbias & 0x3FF;
  sample += bias;
  if (sample >= 0x400) sample = 0x3FF;
  else if (sample < 0) sample = 0;
  return (int16_t)(((sample - bias) * MASTER_VOLUME * 3) >> 4);
}

/* Mixes the samples due up to +timestamp+, in the stretch under way. */
static void audio_sample(rg_bios_boot *b, uint32_t timestamp) {
  int32_t elapsed = (int32_t)(timestamp - b->last_sample) - b->sample_index * b->sample_interval;
  int most = 2 << bias_resolution(b->soundbias);
  int sample;
  for (sample = b->sample_index; elapsed >= b->sample_interval && sample < most; ++sample, elapsed -= b->sample_interval) {
    int left = 0, right = 0;
    int a = (b->fifo[0].samples[sample] * 4) >> !b->volume_a;
    int bb = (b->fifo[1].samples[sample] * 4) >> !b->volume_b;
    if (b->a_left) left += a;
    if (b->a_right) right += a;
    if (b->b_left) left += bb;
    if (b->b_right) right += bb;
    b->current_samples[sample][0] = apply_bias(b, (int16_t)left);
    b->current_samples[sample][1] = apply_bias(b, (int16_t)right);
  }
  b->sample_index = sample;
  if (sample == most) {
    b->last_sample += SAMPLE_TICK_CYCLES;
    b->sample_index = 0;
  }
}

/* A stretch of 1,024 cycles is over: its samples are mixed and kept as the frame's sound. */
static void on_audio_event(rg_bios_boot *b, uint32_t late) {
  audio_sample(b, now32(b) - late);
  int samples = 2 << bias_resolution(b->soundbias);
  for (int f = 0; f < 2; f++) memset(b->fifo[f].samples, (uint8_t)b->fifo[f].samples[samples - 1], sizeof b->fifo[f].samples);
  for (int i = 0; i < samples; i++) {
    if (b->frame_sound_count < RG_BIOS_BOOT_SOUND_MOST) {
      b->frame_sound[2 * b->frame_sound_count] = b->current_samples[i][0];
      b->frame_sound[2 * b->frame_sound_count + 1] = b->current_samples[i][1];
      b->frame_sound_count++;
    }
  }
  schedule(b, EVENT_AUDIO, SAMPLE_TICK_CYCLES - (int32_t)late);
}

static uint32_t audio_write_fifo(rg_bios_boot *b, uint32_t address, uint32_t value) {
  boot_fifo *fifo = &b->fifo[address == REG_FIFO_A_LO ? 0 : 1];
  fifo->words[fifo->write] = value;
  if (++fifo->write == FIFO_WORDS) fifo->write = 0;
  return fifo->words[fifo->write];
}

static void audio_write_soundcnt_hi(rg_bios_boot *b, uint16_t value) {
  b->volume = value & 3;
  b->volume_a = (value >> 2) & 1;
  b->volume_b = (value >> 3) & 1;
  b->a_right = (value >> 8) & 1;
  b->a_left = (value >> 9) & 1;
  b->a_timer = (value >> 10) & 1;
  b->b_right = (value >> 12) & 1;
  b->b_left = (value >> 13) & 1;
  b->b_timer = (value >> 14) & 1;
  if (value & 0x0800u) b->fifo[0].write = b->fifo[0].read = 0;
  if (value & 0x8000u) b->fifo[1].write = b->fifo[1].read = 0;
}

static void audio_write_soundcnt_x(rg_bios_boot *b, uint16_t value) {
  audio_sample(b, now32(b));
  b->audio_enable = (value & 0x80u) != 0;
  if (!b->audio_enable) {
    for (uint32_t i = REG_SOUND1CNT_LO; i < REG_SOUNDCNT_HI; i += 2) b->io[i >> 1] = 0;
    b->volume = 0;
    b->volume_a = b->volume_b = 0;
    b->io[REG_SOUNDCNT_HI >> 1] &= 0xFF00u;
  }
}

static void audio_write_soundbias(rg_bios_boot *b, uint16_t value) {
  uint32_t timestamp = now32(b);
  audio_sample(b, timestamp);
  b->soundbias = value;
  int32_t old_interval = b->sample_interval;
  b->sample_interval = 0x200 >> bias_resolution(value);
  if (old_interval != b->sample_interval) {
    int32_t since = (int32_t)(timestamp - b->last_sample);
    b->sample_index = since >> (9 - bias_resolution(value));
    if (b->sample_index < 0 || b->sample_index >= MOST_SAMPLES_A_TICK) b->sample_index = 0;
  }
}

/* A copy engine pointed at a queue is a sound copy: four words at a time, to the same place. */
static void audio_schedule_fifo_dma(rg_bios_boot *b, int number, boot_dma *info) {
  info->reg = (uint16_t)((info->reg & ~0x0060u) | 0x0040u | 0x0400u); /* the destination fixed, 32 bits */
  switch (info->dest) {
  case 0x04000000u | REG_FIFO_A_LO: b->fifo[0].dma_source = number; break;
  case 0x04000000u | REG_FIFO_B_LO: b->fifo[1].dma_source = number; break;
  default: note_unhandled(b, "a sound copy to somewhere that is not a queue", info->dest); break;
  }
}

/* The voice's timer ran out: it asks its copy for more if the queue has room, moves on to its next
 * sample, and that sample is the voice's from this moment to the end of the stretch. */
static void audio_sample_fifo(rg_bios_boot *b, int fifo_id, int32_t cycles) {
  boot_fifo *fifo = &b->fifo[fifo_id];
  int size = fifo->write >= fifo->read ? fifo->write - fifo->read : FIFO_WORDS - fifo->read + fifo->write;
  if (FIFO_WORDS - size > 4 && fifo->dma_source > 0) {
    boot_dma *dma = &b->dma[fifo->dma_source];
    if (DMA_TIMING(dma->reg) == DMA_TIMING_CUSTOM) {
      dma->when = now32(b) - (uint32_t)cycles;
      dma->next_count = 4;
      dma_schedule(b, fifo->dma_source, dma);
    }
  }
  if (!fifo->internal_remaining && size) {
    fifo->internal_sample = fifo->words[fifo->read];
    fifo->internal_remaining = 4;
    if (++fifo->read == FIFO_WORDS) fifo->read = 0;
  }
  unsigned resolution = bias_resolution(b->soundbias);
  int32_t until = until_event(b, EVENT_AUDIO) - 1;
  int bits = 2 << resolution;
  until += 1 << (9 - resolution);
  until >>= 9 - resolution;
  if (bits < until) until = bits;
  for (int i = bits - until; i < bits; ++i) fifo->samples[i] = (int8_t)(uint8_t)fifo->internal_sample;
  if (fifo->internal_remaining) {
    fifo->internal_sample >>= 8;
    --fifo->internal_remaining;
  }
}
