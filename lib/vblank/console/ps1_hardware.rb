# frozen_string_literal: true

module VBlank
  module Console
    # THE PLAYSTATION'S HARDWARE, NAMED: where its memory is, the addresses of its ports, and the
    # commands its graphics chip takes. Names and numbers follow psx-spx (nocash's PlayStation
    # specification, psx-spx.consoledev.net), so anyone who has read it recognises them.
    #
    # THE PROCESSOR IS A MIPS R3000A, AND IT IS LITTLE-ENDIAN like the Advance's: a number's low byte
    # is at the lower address. It sees 4 gigabytes of addresses, and the console's memory is in them
    # three times over: from 00000000h, from 80000000h (KSEG0, through the instruction cache, where
    # code runs) and from A0000000h (KSEG1, never cached). The low 29 bits give which byte it is.
    #
    #   80000000h-801FFFFFh  main RAM, 2 megabytes. The first 64K belong to the BIOS's kernel, and a
    #                        program (a PS-X EXE) is loaded at 80010000h by convention.
    #   1F800000h-1F8003FFh  the scratchpad: 1K of very fast memory inside the processor
    #   1F801000h-1F802FFFh  the ports: interrupts, DMA, timers, the graphics chip, sound, the pads
    #   BFC00000h-BFC7FFFFh  the BIOS, 512K. The runtime never calls it.
    #
    # THE GRAPHICS CHIP (the GPU) has a megabyte of video RAM of its own, 1024 by 512 pixels of 16
    # bits, which the processor cannot read or write directly: everything goes through two ports. GP0
    # takes drawing commands (fill this rectangle, draw this triangle, copy this picture in) and GP1
    # takes display commands (show the picture starting at this place in video RAM, this big, now).
    # The picture on the television is a rectangle of video RAM; the rest is free for pictures.
    #
    # COLOURS ARE 15 BITS in video RAM, red in the low five, then green, then blue (the top bit is a
    # mask bit no game here uses): the Advance's own layout. A command names a colour in 24 bits, a
    # byte each of red, green and blue, and the chip keeps the top five bits of each.
    module PS1Hardware
      # --- memory ---
      RAM = 0x8000_0000
      RAM_SIZE = 0x20_0000
      KERNEL_SIZE = 0x1_0000
      EXE_AT = RAM + KERNEL_SIZE # The first byte a program owns, where a PS-X EXE is loaded by convention
      RAM_END = RAM + RAM_SIZE
      # Where the stack starts, at the top of RAM less a few words: the MIPS habit keeps the 16 bytes over
      # the pointer for a routine's arguments. The PS-X EXE's header names it, and the runtime sets it.
      STACK_TOP = RAM_END - 0x10
      # The stack's room, the top 32K of RAM, and how far a program and what the game keeps may reach
      # below it. VBlank's build puts what the game keeps first and the program after it
      # (Backends::PS1::Memory), so a PS-X EXE is loaded wherever that ends and stops here.
      STACK_BYTES = 0x8000
      PROGRAM_END = RAM_END - STACK_BYTES
      SCRATCHPAD = 0x1F80_0000
      SCRATCHPAD_SIZE = 0x400
      # Where the processor goes when an interrupt or another exception happens, with the status
      # register's BEV bit clear: an address in the kernel's part of RAM, which the runtime takes over.
      EXCEPTION_VECTOR = 0x8000_0080
      # The low 21 bits of an address in main RAM are the byte's place in the 2 megabytes.
      RAM_MASK = RAM_SIZE - 1
      # The processor's cache control register, and the value Sony's BIOS leaves in it: the instruction
      # cache and the scratchpad on (psx-spx, "Cache Control").
      CACHE_CONTROL = 0xFFFE_0130
      CACHE_CONTROL_SET_BY_BIOS = 0x0001_E988
      # The two values the cache is emptied with (Runtime::Boot#emit_instruction_cache_emptied): the
      # cache on in its tag test mode, where a store marks a line as holding nothing, and the cache on.
      CACHE_CONTROL_TAG_TEST = 0x0000_0804
      CACHE_CONTROL_CACHE_ON = 0x0000_0800
      # The instruction cache: 4K of instructions, kept in lines of four.
      INSTRUCTION_CACHE_BYTES = 0x1000
      INSTRUCTION_CACHE_LINE_BYTES = 16
      # RAM again where nothing is fetched through the cache (KSEG1): an address in RAM with this bit
      # set as well names the same byte.
      UNCACHED = 0x2000_0000
      # The status register's "isolate cache" bit: loads and stores go to the cache and nowhere else.
      SR_ISOLATE_CACHE = 1 << 16

      # --- the ports, all reached from one register holding 1F800000h, at a 16-bit distance ---
      IO = 0x1F80_0000
      I_STAT = 0x1F80_1070 # Which interrupts have happened; a 0 written to a bit clears it
      I_MASK = 0x1F80_1074 # Which of them reach the processor
      GP0 = 0x1F80_1810 # Drawing commands in; read, it answers a VRAM read
      GP1 = 0x1F80_1814 # Display commands in; read, it is GPUSTAT
      DPCR = 0x1F80_10F0 # Which DMA channels are on
      DMA2_MADR = 0x1F80_10A0 # The graphics chip's DMA: where in RAM
      DMA2_BCR = 0x1F80_10A4 # How many words
      DMA2_CHCR = 0x1F80_10A8 # How, and go
      JOY_DATA = 0x1F80_1040 # The pads' and memory cards' serial port (SIO0): a byte out and a byte back
      JOY_STAT = 0x1F80_1044
      JOY_MODE = 0x1F80_1048
      JOY_CTRL = 0x1F80_104A
      JOY_BAUD = 0x1F80_104E
      SPU_MAIN_VOLUME = 0x1F80_1D80
      SPU_CONTROL = 0x1F80_1DAA

      # --- the sound chip (SPU), its registers 16 bits each from SPU (psx-spx, "Sound Processing Unit") ---
      SPU = 0x1F80_1C00
      # A voice's registers, 10h apart, from SPU + voice * 10h:
      SPU_VOICE_BYTES = 0x10
      SPU_VOLUME_LEFT = 0x0 # Bit 15 clear: a fixed volume, half the loudness in bits 0-14
      SPU_VOLUME_RIGHT = 0x2
      SPU_PITCH = 0x4 # How fast it reads its sound: 1000h is 44100 samples a second
      SPU_START = 0x6 # Where its sound starts in sound memory, counted in 8-byte steps
      SPU_ADSR_LOW = 0x8 # Its envelope: attack, decay and sustain level
      SPU_ADSR_HIGH = 0xA # ...sustain and release
      SPU_REPEAT = 0xE # Where its loop goes back to, in 8-byte steps; written, it holds until the next key on
      # The chip's own, as distances from SPU:
      SPU_KEY_ON = 0x188 # Voices 0-15 started, a bit each (voices 16-23 at 18Ah)
      SPU_KEY_OFF = 0x18C # Voices 0-15 let go, a bit each (16-23 at 18Eh)
      SPU_TRANSFER_ADDRESS = 0x1A6 # Where in sound memory the next written halfword goes, in 8-byte steps
      SPU_TRANSFER_FIFO = 0x1A8 # Halfwords for sound memory, 32 at a time
      SPU_CONTROL_AT = 0x1AA
      SPU_RAM_CONTROL = 0x1AC # 0004h before sound memory is reached, as psx-spx says
      SPU_STATUS = 0x1AE
      # SPU_CONTROL's bits: the chip on, its sound let out, and how sound memory is reached.
      SPU_ON = 0x8000
      SPU_UNMUTED = 0x4000
      SPU_MANUAL_WRITE = 0x0010
      SPU_TRANSFER_MODE = 0x0030
      SPU_RAM_CONTROL_NORMAL = 0x0004
      # SPU_STATUS's bit: the chip still busy with a transfer.
      SPU_TRANSFER_BUSY = 0x0400
      # The loudest the main volume, a fixed volume of the same shape as a voice's.
      SPU_MAIN_LOUDEST = 0x3FFF
      # The first byte of sound memory a program's sounds may use: the first 1000h hold what the chip
      # writes as it plays, the CD's sound and voices 1 and 3 (psx-spx, "SPU Memory layout").
      SPU_FIRST_FREE = 0x1000
      SPU_RAM_BYTES = 0x8_0000
      # The second of the three timers: its count, 16 bits that turn round, and how it counts. Told to
      # count the ends of lines (TIMER1_COUNTS_LINES, the clock source bits set to the horizontal
      # retrace) and never to stop or start again, it counts how many lines the screen has drawn, so two
      # readings show how many lines went by between them (psx-spx, "Timers").
      TIMER1_COUNT = 0x1F80_1110
      TIMER1_MODE = 0x1F80_1114
      TIMER1_COUNTS_LINES = 0x0100

      # --- interrupts (I_STAT and I_MASK bits) ---
      IRQ_VBLANK = 1 << 0
      IRQ_PAD = 1 << 7 # A pad or memory card has acknowledged a byte
      # The status register's bits: the hardware interrupt line (IM2, which every one of the ports'
      # interrupts comes in on) and interrupts on (IEc).
      SR_INTERRUPTS_ON = (1 << 10) | 1

      # --- the graphics chip ---
      # GP1 commands: the command in the top byte, its setting below.
      GP1_RESET = 0x00 << 24
      GP1_DISPLAY_ON = 0x03 << 24 # Bit 0 clear: on
      GP1_DISPLAY_START = 0x05 << 24 # X | y << 10: the top left of the picture shown, in video RAM
      GP1_HORIZONTAL_RANGE = 0x06 << 24 # x1 | x2 << 12, in the chip's dot clock
      GP1_VERTICAL_RANGE = 0x07 << 24 # y1 | y2 << 10, in lines
      GP1_DISPLAY_MODE = 0x08 << 24
      GP1_DMA_DIRECTION = 0x04 << 24 # 0 off, 2 the DMA controller hands words to GP0
      DMA_TO_GP0 = 2

      # --- DMA ---
      # DPCR: channel 2's enable bit (bit 3 of its nibble).
      DPCR_GPU_ON = 1 << 11
      # CHCR: from RAM, a block each time the device asks (sync mode 1), and start (bit 24).
      DMA2_FROM_RAM_BY_BLOCKS = 0x0100_0201
      # CHCR: from RAM, following a linked list of nodes (sync mode 2), and start. Each node is a header
      # word, how many words follow in its top byte and where the next node is below, then those words.
      DMA2_FROM_RAM_BY_LIST = 0x0100_0401
      DMA_BUSY = 1 << 24
      # 320 pixels across, 240 lines, NTSC, 15-bit colour, not interlaced.
      DISPLAY_MODE_320_BY_240 = 0x01
      # Where the 320 visible pixels sit on an NTSC line (eight of the chip's clocks a pixel), and the
      # 240 visible lines: the ranges psx-spx gives as the usual ones.
      HORIZONTAL_FIRST = 0x260
      HORIZONTAL_LAST = HORIZONTAL_FIRST + (320 * 8)
      VERTICAL_FIRST = 0x10
      VERTICAL_LAST = VERTICAL_FIRST + 240

      # GPUSTAT (GP1 read), bit 28: the chip's command queue has room for another word. (Bit 26, "ready
      # for a command", also asks that the chip be idle, and Beetle PSX does not set it until the chip's
      # time has moved on, which a loop that only reads the port never lets it do.)
      GPUSTAT_READY_FOR_COMMAND = 1 << 28
      # GPUSTAT bits 26 and 28 both set: the chip idle, ready for a command, and its queue empty, so
      # everything it was sent is drawn. A wait for this is fine once nothing more is being sent (Beetle
      # PSX measured: it came at the end of each pass's list of drawing commands).
      GPUSTAT_DRAWN = (1 << 26) | GPUSTAT_READY_FOR_COMMAND

      # GP0 commands.
      GP0_CLEAR_CACHE = 0x01 << 24 # The texture cache emptied, so texels copied in since are read afresh
      GP0_FILL = 0x02 << 24 # Colour, then y << 16 | x, then height << 16 | width
      # A flat rectangle of any size, in the colour in the command's low 24 bits: then y << 16 | x, then
      # height << 16 | width. It is held to the drawing area, and a rectangle is never dithered.
      GP0_RECTANGLE = 0x60 << 24
      # A rectangle of any size textured from the page the draw mode names, each texel copied as it is
      # (raw: no colour mixed in) and none see-through by halves: then y << 16 | x, then the colour table
      # << 16 | v << 8 | u, then height << 16 | width. A texel of 0000h, or a number into a colour table
      # whose entry is 0000h, is not drawn.
      GP0_TEXTURED_RECTANGLE = 0x65 << 24
      # A copy from the processor into video RAM: then y << 16 | x, then height << 16 | width, then the
      # pixels two to a word, the left one in the low half.
      GP0_COPY_TO_VRAM = 0xA0 << 24
      # A copy from one place in video RAM to another: then where from (y << 16 | x), where to, then
      # height << 16 | width.
      GP0_COPY_IN_VRAM = 0x80 << 24
      # The draw mode's texture page: its left edge in 64s of pixels (bits 0-3) and its top in 256s
      # (bit 4); bits 7-8 its depth, 0 for 4-bit and 1 for 8-bit numbers into a colour table (CLUT), and
      # TEXTURE_15_BIT for colours of 15 bits, one a pixel (Backends::PS1::TextureMemory);
      # DRAW_ON_SHOWN_PICTURE lets a command draw where the picture shown is, which a screen of one page
      # always does.
      TEXTURE_15_BIT = 2 << 7
      DRAW_ON_SHOWN_PICTURE = 1 << 10
      # A texel's top bit. With it set a black texel (0000h, which the chip never draws) is drawn black;
      # the picture shown is read with the top bit dropped, as the chip shows it.
      TEXEL_DRAWN = 0x8000
      # A triangle textured from a page, each texel copied as it is (raw) and none see-through by
      # halves: then for each corner y << 16 | x and v << 8 | u, the first corner's u and v word
      # carrying the colour table in its top half and the second's the texture page (the draw mode's
      # bits 0 to 8). The place on the picture steps straight across it from the corners'.
      GP0_TEXTURED_TRIANGLE = 0x25 << 24
      # A shaded textured triangle: each corner's colour (red, green and blue, a byte each, in the low 24
      # bits; the first's in the command word itself) before its place, and each texel multiplied by the
      # colour stepped across the triangle, 80h the texel as it is (psx-spx, "GPU Render Polygon Commands").
      GP0_SHADED_TEXTURED_TRIANGLE = 0x34 << 24
      GP0_DRAW_MODE = 0xE1 << 24
      # The texture window: a power-of-two part of the page a texture repeats in. Bits 0-4 are which bits
      # of u are replaced (in eights of a texel's place: (256 - width) / 8), bits 5-9 the same of v, bits
      # 10-14 and 15-19 what they are replaced with (where the texture starts, in eights). Nought for
      # none: the whole page.
      GP0_TEXTURE_WINDOW = 0xE2 << 24
      GP0_DRAWING_AREA_TOP_LEFT = 0xE3 << 24 # X | y << 10
      GP0_DRAWING_AREA_BOTTOM_RIGHT = 0xE4 << 24
      GP0_DRAWING_OFFSET = 0xE5 << 24 # X | y << 11, each signed 11 bits

      SCREEN_WIDTH = 320
      SCREEN_HEIGHT = 240
      VRAM_WIDTH = 1024
      VRAM_HEIGHT = 512

      module_function

      # A colour as a GP0 command names it, 24 bits with red in the low byte, from a 15-bit colour with red in
      # the low five bits: each five-bit channel in the top of its byte, so the chip keeps exactly those bits.
      def command_color(color15)
        red = color15 & 0x1F
        green = (color15 >> 5) & 0x1F
        blue = (color15 >> 10) & 0x1F
        (red << 3) | (green << 11) | (blue << 19)
      end
    end
  end
end
