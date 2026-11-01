# frozen_string_literal: true

module VBlank
  module Console
    # THE SEGA GENESIS'S HARDWARE, NAMED: where its memory is, the addresses and flags of the video
    # chip's ports and registers, the pads and the boot checks. Names follow the ones Sega's own
    # Genesis Software Manual, Charles MacDonald's video chip notes and SGDK use, so anyone who has
    # read one recognises them. What is written here was checked against the source of Genesis Plus
    # GX (core/vdp_ctrl.c, core/io_ctrl.c, core/loadrom.c) and SGDK (src/boot/sega.s).
    #
    # THE PROCESSOR IS A MOTOROLA 68000, AND IT IS BIG-ENDIAN. A number wider than a byte is kept with
    # its high byte at the lower address: $1234 at address 0 is $12 at 0 and $34 at 1. Every other
    # console VBlank builds for keeps the low byte first, so a number read from the Genesis's memory
    # one byte at a time is put together the other way round.
    #
    # THE PROCESSOR REACHES 16 MEGABYTES OF ADDRESSES (24 bits), and the console and a cartridge
    # share them like this:
    #
    #   $000000-$3FFFFF  the cartridge, up to 4 megabytes
    #   $A00000-$A0FFFF  the sound processor's (Z80) memory, usable only while the 68000 holds its bus
    #   $A10000-$A1001F  the pads' ports and the console's version register
    #   $A11100          the Z80's bus request; $A11200 its reset
    #   $A14000          the security check ("TMSS"), on a console that has one
    #   $C00000-$C0001F  the video chip's ports: data at $C00000, control at $C00004, the
    #                    horizontal and vertical counter at $C00008, the sound chip's PSG at $C00011
    #   $FF0000-$FFFFFF  work RAM, 64K (the same 64K is seen again at every 64K step from $E00000)
    #
    # Work RAM is the only memory a game's variables can live in, and it holds the stack too. Video
    # RAM (64K: the tiles, the maps of them, the sprite table), the colour memory (64 colours) and the
    # vertical scroll memory (40 words) belong to the video chip. They are not in the processor's
    # view at all: they are reached through the chip's two ports, a word at a time.
    #
    # A WORD OR A LONG WORD MUST BE AT AN EVEN ADDRESS. The 68000 reads memory in 16-bit steps, and
    # asked for a word at an odd address it stops with an address error instead of reading. The
    # Game Boy Advance and the Game Boy Color forgive an odd address (the Advance rotates what it
    # reads, the Color has no word reads at all), so this is the one console here where a
    # misplaced variable stops the game. Every place the build gives out is even.
    #
    # COLOURS ARE 9 BITS: three each of red, green and blue, so a picture has 512 colours to choose
    # from and not the 32768 of the other consoles. A colour is written as a 16-bit word in the
    # colour memory with the channels in the upper bit of each nibble: 0000 BBB0 GGG0 RRR0. A game
    # still names a colour in 15 bits, and the build keeps the top three bits of each channel
    # (Console::GenesisHardware.color_word); the interpreter shows the same top three bits
    # (Console::Description#color_bits), or no picture could ever agree.
    module GenesisHardware
      # --- memory ---
      WRAM = 0xFF0000 # all 64K of work RAM starts here
      WRAM_SIZE = 0x10000
      VRAM_SIZE = 0x10000
      CRAM_COLORS = 64 # four lists of sixteen
      VSRAM_WORDS = 40
      CARTRIDGE_END = 0x400000

      # --- the video chip's ports ---
      VDP_DATA = 0xC00000 # a word written here goes where the last command pointed
      VDP_CONTROL = 0xC00004 # commands and register writes; read, it is the status
      VDP_COUNTER = 0xC00008 # the beam's place: vertical counter in the high byte
      PSG = 0xC00011 # the sound chip's square voices, written a byte at a time

      # A register write is one word to the control port: $80 + the register's number in the high
      # byte, and the value in the low byte (`VDP_REGISTER | (number << 8) | value`).
      VDP_REGISTER = 0x8000

      # The registers that matter to a game's picture, by number.
      REG_MODE1 = 0 # bit 4: the horizontal interrupt; bit 2 must be set
      REG_MODE2 = 1 # bit 6: the screen on; bit 5: the vertical interrupt; bit 3: 30 rows of tiles; bit 2: mode 5
      REG_PLANE_A = 2 # where plane A's map is, in video RAM: the address's top bits (value << 10)
      REG_WINDOW = 3 # where the window's map is (value << 10)
      REG_PLANE_B = 4 # where plane B's map is (value << 13)
      REG_SPRITES = 5 # where the sprite table is (value << 9)
      REG_BACKDROP = 7 # which colour shows where no plane or sprite does: list in bits 5-4, colour in 3-0
      REG_HINT = 10 # the lines between horizontal interrupts
      REG_MODE3 = 11 # how the planes scroll: whole screen, or by row (bits 1-0 horizontal, bit 2 vertical)
      REG_MODE4 = 12 # bit 0 (and bit 7): 40 tiles across, not 32; bits 2-1: interlace
      REG_HSCROLL = 13 # where the horizontal scroll table is (value << 10)
      REG_INCREMENT = 15 # how far the address moves after each write
      REG_PLANE_SIZE = 16 # the planes' sizes: bits 1-0 across, bits 5-4 down (0 is 32, 1 is 64, 3 is 128)
      REG_WINDOW_X = 17
      REG_WINDOW_Y = 18
      REG_DMA_LENGTH_LOW = 19
      REG_DMA_LENGTH_HIGH = 20
      REG_DMA_SOURCE_LOW = 21
      REG_DMA_SOURCE_MIDDLE = 22
      REG_DMA_SOURCE_HIGH = 23 # and the kind of copy, in the top two bits

      # Register values a game's set-up writes.
      MODE1_NORMAL = 0x04
      MODE2_SCREEN_ON = 0x44 # mode 5, the screen on, no interrupt
      MODE2_SCREEN_OFF = 0x04
      MODE2_VBLANK_INTERRUPT = 0x20 # added to switch the vertical blank's interrupt on
      MODE4_40_CELLS = 0x81 # 320 pixels across
      INCREMENT_WORD = 2

      # What a command long word to the control port asks for: the kind of memory in bits 31-30 and
      # 5-4 and the address in the rest. `command(KIND, address)` makes it. The address's low
      # 14 bits go in bits 29-16 and its top two bits in bits 1-0.
      WRITE_VRAM = 0x40000000
      WRITE_CRAM = 0xC0000000
      WRITE_VSRAM = 0x40000010
      READ_VRAM = 0x00000000

      # --- the pads ---
      #
      # A pad is read through a port of three bytes: data, control and serial, at odd addresses (the
      # chip is on the processor's low byte). Port 1 is $A10003 data and $A10009 control; port 2 is
      # $A10005 and $A1000B. The control byte says which pins the processor drives: $40 makes pin 6
      # (TH) an output, which the pad uses to choose which half of its buttons it shows. With TH
      # high the pad shows, in bits 5-0, C, B, right, left, down, up, and with TH low it shows
      # start and A in bits 5 and 4 (and down and up as before). A pressed button reads 0.
      VERSION_REGISTER = 0xA10001
      PAD1_DATA = 0xA10003
      PAD2_DATA = 0xA10005
      PAD1_CONTROL = 0xA10009
      PAD2_CONTROL = 0xA1000B
      PAD_TH = 0x40

      # Each pad button's bit with TH high ("high") and with TH low ("low").
      PAD_BITS = Ractor.make_shareable({
        up: [:high, 0], down: [:high, 1], left: [:high, 2], right: [:high, 3], b: [:high, 4], c: [:high, 5],
        a: [:low, 4], start: [:low, 5]
      })

      # --- the boot checks ---
      #
      # A console of the later kind (its version register, $A10001, has a version number in the low
      # four bits that is not 0) refuses to show the cartridge's picture until the cartridge has
      # written the four letters SEGA to $A14000: the TMSS, a trademark check. An earlier console has
      # none, and a write there goes nowhere. The write is made at power-on, and only when the version
      # says to.
      TMSS_PORT = 0xA14000
      TMSS_LICENSE = 0x53454741 # "SEGA"
      TMSS_VERSION_MASK = 0x0F

      # The sound processor. It starts running its own (empty) memory at power-on, which can write
      # noise into the sound chip, so the game's boot asks for its bus and holds it still. A request
      # is a word of $0100 to $A11100; the bus is the game's once bit 0 of what is read there is 0.
      Z80_BUS_REQUEST = 0xA11100
      Z80_RESET = 0xA11200
      Z80_REQUEST = 0x0100

      # The four commands that turn the PSG's four voices off (a volume of 15 on each).
      PSG_SILENCE = [0x9F, 0xBF, 0xDF, 0xFF].freeze

      # --- the header ---
      #
      # The cartridge starts with 64 vectors of four bytes (the stack's first place, where to start,
      # then the exceptions and interrupts), then a 256-byte header from $100, then code from $200.
      # An emulator or a flash cart reads the header to know what the cartridge is; the console
      # itself reads none of it but the vectors and the two letters "SEGA" some boards look for at
      # $100. The checksum at $18E is the sum of every 16-bit word from $200 to the end of the
      # cartridge, kept to 16 bits.
      HEADER_AT = 0x100
      CONSOLE_NAME_AT = 0x100 # "SEGA MEGA DRIVE " (or "SEGA GENESIS    ")
      COPYRIGHT_AT = 0x110
      DOMESTIC_NAME_AT = 0x120
      OVERSEAS_NAME_AT = 0x150
      SERIAL_AT = 0x180
      CHECKSUM_AT = 0x18E
      DEVICES_AT = 0x190
      ROM_START_AT = 0x1A0
      ROM_END_AT = 0x1A4
      RAM_START_AT = 0x1A8
      RAM_END_AT = 0x1AC
      REGION_AT = 0x1F0
      CODE_AT = 0x200
      TITLE_LENGTH = 48

      # The vectors, by the name the lowering gives each: where in the first 256 bytes the address
      # goes. The vertical blank's interrupt is level 6, the horizontal one level 4.
      VECTORS = Ractor.make_shareable({
        stack: 0x00, reset: 0x04, bus_error: 0x08, address_error: 0x0C, illegal: 0x10, zero_divide: 0x14,
        chk: 0x18, trapv: 0x1C, privilege: 0x20, trace: 0x24, line_a: 0x28, line_f: 0x2C,
        horizontal_interrupt: 0x70, vertical_interrupt: 0x78
      })

      module_function

      # +color+ (15 bits, red in the low five) as the colour memory takes it: the top three bits of
      # each channel, laid out 0000 BBB0 GGG0 RRR0.
      def color_word(color)
        ((((color >> 2) & 7) << 1) | (((color >> 7) & 7) << 5) | (((color >> 12) & 7) << 9))
      end

      # +color+ as 15 bits again once it has been through the colour memory: each of the three bits
      # widened to five (the bits repeated, so the brightest is 31 and the darkest 0). What the
      # picture of a Genesis is read back as, and what the interpreter shows.
      def shown_color(color)
        widened = [0, 5, 10].map { |at| widen(((color >> (at + 2)) & 7)) << at }
        widened.sum
      end

      # A channel of three bits widened to five.
      def widen(level) = (level << 2) | (level >> 1)

      # The command long word that points the chip at +address+ of the memory +kind+ names
      # (WRITE_VRAM and the rest).
      def command(kind, address) = kind | ((address & 0x3FFF) << 16) | ((address >> 14) & 3)
    end
  end
end
