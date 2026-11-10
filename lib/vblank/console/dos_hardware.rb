# frozen_string_literal: true

module VBlank
  module Console
    # DOS'S HARDWARE, NAMED: where a PC keeps its memory, the ports a program talks to its video card,
    # sound cards and keyboard through, and the numbers it sends. Names and numbers follow Michael
    # Abrash's Graphics Programming Black Book (the VGA), Creative's Sound Blaster programming guide
    # and Yamaha's YM3812 sheet (the AdLib's OPL2), so anyone who has read them recognises each.
    #
    # THE PROCESSOR IS AN 80386 IN REAL MODE, and it is little-endian: a number's low byte is at the
    # lower address. An address is a SEGMENT and an OFFSET, each 16 bits, and the byte it names is at
    # segment * 16 + offset. So memory is seen in windows of 64K, and a number a program keeps in one
    # window is reached through the register that holds the window's segment. The 32-bit registers
    # work in real mode too, through the operand-size prefix (66h), which is how a 32-bit number is
    # one operation here.
    #
    #   00000h-9FFFFh  conventional memory, 640K. DOS and the program are here.
    #   A0000h-AFFFFh  the VGA card's memory, 64K, a window onto the card's own
    #   B8000h-BFFFFh  text mode's memory, which no game here uses
    #   F0000h-FFFFFh  the BIOS
    #
    # THE VGA CARD keeps a picture in memory of its own and shows it. In MODE 13H (320 × 200, 256
    # colours) each byte at A000:0000 is one pixel, a number into the card's PALETTE of 256 colours.
    # The palette is set through two ports: write the number of the first colour to 3C8h, then write
    # red, green and blue, six bits each (0 to 63), to 3C9h, once for each colour. MODE X is the same
    # card unchained: the four planes of memory are written one at a time (by the sequencer's map mask,
    # port 3C4h, index 2), which gives 320 × 240 and more than one page of memory. VESA mode 101h
    # (640 × 480, 256 colours) shows more than 64K of picture, so the card's memory is reached in
    # banks, 64K at a time, which the VESA BIOS (INT 10h, AX = 4F05h) switches.
    #
    # A FRAME is one vertical retrace: bit 3 of the card's status port (3DAh) is 1 while the electron
    # beam returns from the bottom of the screen to the top, and a program waits for it to be 0 and
    # then 1 to start a frame on the first line of the retrace. Mode 13h and Mode X draw 449 lines of
    # 800 dots at 25.175 MHz, which is 70.087 frames a second; the 640 × 480 mode draws 525 lines of
    # 800 dots, which is 59.94.
    module DOSHardware
      # --- memory ---
      CONVENTIONAL_MEMORY = 640 * 1024
      SEGMENT_SIZE = 0x1_0000
      VIDEO_SEGMENT = 0xA000

      # --- video ---
      MODE_13H = 0x13
      MODE_X_COLUMNS = 320
      MODE_X_ROWS = 240
      VESA_MODE_640X480 = 0x101
      DAC_WRITE_INDEX = 0x3C8
      DAC_DATA = 0x3C9
      INPUT_STATUS = 0x3DA
      RETRACE_BIT = 0x08
      SEQUENCER_INDEX = 0x3C4
      SEQUENCER_DATA = 0x3C5
      MAP_MASK = 2
      # The dots and lines of one frame, and the speed the card counts dots at.
      DOT_CLOCK = 25_175_000
      DOTS_A_LINE = 800
      LINES_A_FRAME = { mode_13h: 449, mode_x: 525, vesa_640x480: 525 }.freeze
      # The card keeps six bits of each colour.
      DAC_BITS = 6

      # --- sound: the AdLib (an OPL2, the YM3812) ---
      ADLIB_REGISTER = 0x388
      ADLIB_DATA = 0x389
      ADLIB_VOICES = 9
      ADLIB_RATE = 49_716

      # --- sound: the Sound Blaster, at the settings every game assumes (BLASTER=A220 I5 D1) ---
      SOUND_BLASTER_BASE = 0x220
      SOUND_BLASTER_IRQ = 5
      SOUND_BLASTER_DMA = 1
      BLASTER_SETTING = "A220 I5 D1"

      # --- keyboard: the scan codes the keyboard port (60h) says, from IBM's set 1 ---
      KEYBOARD_PORT = 0x60
      KEYBOARD_IRQ = 1
      EXTENDED_KEY = 0xE0
      # A key is let go with its scan code plus this.
      RELEASE_BIT = 0x80
      # The buttons a game names, to the keys that are them. The arrows send EXTENDED_KEY first.
      SCAN_CODES = {
        a: 0x1D,      # Ctrl
        b: 0x38,      # Alt
        start: 0x1C,  # Enter
        select: 0x36, # Right Shift
        l: 0x2C,      # Z
        r: 0x2D,      # X
        up: 0x48, down: 0x50, left: 0x4B, right: 0x4D
      }.freeze
      ARROWS = %i[up down left right].freeze
    end
  end
end
