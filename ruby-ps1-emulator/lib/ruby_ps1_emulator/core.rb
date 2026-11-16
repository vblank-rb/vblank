# frozen_string_literal: true

require "fileutils"
require "tmpdir"

module RubyPS1Emulator
  # ONE PLAYSTATION, PLAYED A FRAME AT A TIME with nobody watching: a program (a PS-X EXE) loaded into
  # Beetle PSX (a libretro core, see CoreLibrary), its buttons set from Ruby, and everything a test wants
  # to read back handed over as plain bytes — main RAM, video RAM and the picture shown in it, the
  # graphics chip's display settings, the scratchpad, the processor's registers, the sound chip's
  # registers and memory, and the sound it made — and where the
  # processor's time went, by address, and how long the graphics chip spent drawing, for a profiler.
  #
  #   core = RubyPS1Emulator::Core.new("game.exe")
  #   core.set_buttons(%i[right cross])
  #   core.run_frame
  #   core.ram_read32(0x80010000)
  #   core.destroy
  #
  # A LIBRETRO CORE IS ONE CONSOLE PER LIBRARY: it keeps the whole machine in the library's own
  # globals. So each Core loads a copy of the library of its own (KeptCopy), and two Cores in one
  # process are two consoles that cannot see each other.
  #
  # The core is played through Frontend, this gem's C extension: it opens the copy, answers what the
  # core asks (a quiet log among it: Beetle tells a log what it finds, or the terminal when it has
  # none), and keeps the sound the core hands over until it is asked for here
  # (ext/ruby_ps1_emulator_ext/libretro_frontend.c says why that is C). So a Core can be made and
  # played in any Ractor.
  #
  # NO BIOS FROM SONY, unless one is handed over. The core is told a system folder with no BIOS in it,
  # so it starts OpenBIOS, the free BIOS built into it. Beetle loads a PS-X EXE by letting the BIOS
  # start and then copying the program into RAM and jumping to it, where the BIOS would have started
  # the disc. OpenBIOS never reaches the place Beetle does that from, so the probe patch starts the
  # program at power-on instead, with no BIOS run at all.
  #
  # A BIOS FROM SONY is the player's own, dumped from their console, and is named when the core is made
  # (+bios+). The core finds a BIOS by its file name in the system folder, so a link to the player's
  # file is put there under the name the core asks for (BIOS_NAME): a link and never a copy, gone with
  # the folder. Then the BIOS runs first, sets its kernel up in RAM as it does on a console, and Beetle
  # starts the program from inside it, so the program finds the console as a BIOS leaves it and not as
  # power-on does.
  #
  # THE PICTURE is read from video RAM, at the place and the size the graphics chip is told to show,
  # never from the picture the core hands its front end (which it crops and widens for a television).
  # So a pixel here is exactly the 15 bits the program drew: red in the low five, then green, then blue.
  class Core
    # libretro's names for the memory card in the first slot and for main RAM, and the probe patch's
    # own (core/beetle-vblank-probe.patch).
    MEMORY_CARD = 0
    SYSTEM_RAM = 2
    VIDEO_RAM = 0x8001
    GPU_STATE = 0x8002
    SCRATCHPAD = 0x8003
    CPU_REGISTERS = 0x8004
    SPU_REGISTERS = 0x8005
    SOUND_RAM = 0x8006
    PROCESSOR_TIME = 0x8007
    GPU_BUSY = 0x8008

    RAM_SIZE = 0x20_0000
    SCRATCHPAD_SIZE = 0x400
    VRAM_WIDTH = 1024
    VRAM_HEIGHT = 512

    # libretro's joypad: the number it asks about each button by. The PlayStation's pad as the core lays
    # it out: its "B" is cross, its "A" circle, its "Y" square and its "X" triangle.
    BUTTONS = { cross: 0, square: 1, select: 2, start: 3, up: 4, down: 5, left: 6, right: 7,
                circle: 8, triangle: 9, l1: 10, r1: 11, l2: 12, r2: 13 }.freeze

    # The graphics chip's settings in the order the probe patch hands them over.
    GPU_STATE_NAMES = %i[display_mode display_off display_x display_y horizontal_start horizontal_end
                         vertical_start vertical_end clip_left clip_top clip_right clip_bottom offset_x offset_y
                         upscale_shift scanline].freeze

    # The processor's registers in the order the probe patch hands them over.
    REGISTER_NAMES = (%i[zero at v0 v1 a0 a1 a2 a3 t0 t1 t2 t3 t4 t5 t6 t7 s0 s1 s2 s3 s4 s5 s6 s7 t8 t9 k0 k1 gp sp fp ra] +
                      %i[lo hi pc]).freeze

    # The widths the display mode's low two bits choose, and the one bit 6 chooses over them.
    WIDTHS = [256, 320, 512, 640].freeze
    WIDTH_368 = 1 << 6

    # The settings the core asks for, as libretro names them: none, so it keeps its own.
    SETTINGS = Ractor.make_shareable({})

    # The picture format the core is let draw in: whichever it asks for, since the picture is read
    # from video RAM and never from what the core hands over.
    ANY_PIXEL_FORMAT = nil

    JOYPAD = 1

    # The name Beetle looks for a North American console's BIOS under in its system folder, the region
    # it takes a PS-X EXE to be for. It takes a file of that name whichever console it was dumped from.
    BIOS_NAME = "scph5501.bin"

    attr_reader :frames

    # How many pairs of sound samples the console has made since power-on. The sound chip makes 44100 a
    # second, one every 768 cycles of the processor, so this is a clock: how long the frames played took.
    attr_reader :sound_frames

    # +exe_path+ is the program. +save_dir+ is where the core is told to keep files; a core made without
    # one keeps them in a folder of its own that is gone with it.
    #
    # +bios+ is the path of a BIOS file to start the console under, the player's own (see "A BIOS FROM
    # SONY" above). Without one the console has OpenBIOS.
    def initialize(exe_path, save_dir: nil, bios: nil)
      raise ArgumentError, "there is no BIOS file at #{bios}" if bios && !File.file?(bios)

      @dir = Dir.mktmpdir("ruby-ps1-emulator")
      File.symlink(File.expand_path(bios), File.join(@dir, BIOS_NAME)) if bios
      @frames = 0
      @sound_frames = 0
      @audio = []
      start_frontend(save_dir || @dir)
      load_program(exe_path)
    end

    # The buttons down on controller +port+ (0 for the first), by name (BUTTONS).
    def set_buttons(buttons, port: 0)
      unknown = buttons - BUTTONS.keys
      raise ArgumentError, "a PlayStation pad has no #{unknown.join(', ')} button" unless unknown.empty?

      @frontend.set_buttons(port, buttons.uniq.sum { |button| 1 << BUTTONS.fetch(button) })
    end

    # Plays one frame.
    def run_frame
      @frontend.run
      take_sound(@frontend.drain_audio)
      @frames += 1
      self
    end

    # --- the picture ---

    # The graphics chip's display and drawing settings by name (GPU_STATE_NAMES).
    def gpu_state
      values = memory(GPU_STATE).unpack("l<*")
      GPU_STATE_NAMES.zip(values).to_h
    end

    # The size of the picture the chip shows: its width from the display mode, its height 240 lines (or
    # 480 when interlaced, bit 5 with bit 2).
    def width
      mode = gpu_state.fetch(:display_mode)
      mode.anybits?(WIDTH_368) ? 368 : WIDTHS.fetch(mode & 3)
    end

    def height = gpu_state.fetch(:display_mode).allbits?(0x24) ? 480 : 240

    # The picture shown: #width × #height 15-bit colours, row by row, read from video RAM where the chip
    # is told the picture starts. A row that runs past video RAM's right edge goes round to its left,
    # as the chip's own reading does.
    def colors
      state = gpu_state
      colors_at(state.fetch(:display_x), state.fetch(:display_y), width, height)
    end

    # The +width+ × +height+ pixels of video RAM whose top left is (+left+, +top+), row by row, each the
    # 15 bits the chip shows (its top bit, the mask bit, dropped). Only those rows are read, in place: a
    # row that runs past video RAM's right edge goes round to its left, and one past the bottom to the
    # top, as the chip's own reading does.
    def colors_at(left, top, width, height)
      left %= VRAM_WIDTH
      before_edge = [width, VRAM_WIDTH - left].min
      Array.new(height) do |row|
        line = ((top + row) % VRAM_HEIGHT) * VRAM_WIDTH * 2
        bytes = @frontend.memory_read(VIDEO_RAM, line + (left * 2), before_edge * 2)
        bytes += @frontend.memory_read(VIDEO_RAM, line, (width - before_edge) * 2) if width > before_edge
        bytes.unpack("v*").map { |color| color & 0x7FFF }
      end.flatten
    end

    # --- the memories ---

    # All 2 megabytes of main RAM, from 80000000h.
    def ram = memory(SYSTEM_RAM)

    # Video RAM: 1024 × 512 pixels of 16 bits, row by row, low byte first.
    def vram = memory(VIDEO_RAM)

    # The scratchpad: 1K at 1F800000h.
    def scratchpad = memory(SCRATCHPAD)

    # The processor's registers by name (REGISTER_NAMES): the 32 general ones, LO, HI and the
    # program counter.
    def registers = REGISTER_NAMES.zip(memory(CPU_REGISTERS).unpack("L<*")).to_h

    # --- the sound ---

    # THE SOUND CHIP'S REGISTERS AS THE PROGRAM LAST WROTE THEM: 256 halfwords from 1F801C00h, by their
    # distance from there in bytes (a voice's are 10h apart from 0, the chip's own from 180h). What a
    # register reads back on the console is not always what was written (key on and key off read as
    # nought, a voice's envelope as where it has got to), so these are kept as written, which is what a
    # check of the program's writes wants.
    def spu_registers = memory(SPU_REGISTERS).unpack("v*").each_with_index.to_h { |value, i| [i * 2, value] }

    # Sound RAM, all 512K of it, as bytes: the ADPCM blocks the program put there.
    def sound_ram = memory(SOUND_RAM)

    # The sound made since this was last asked: left and right in turn, each a signed 16-bit sample, at
    # 44100 pairs a second. What is not asked for piles up, so a reader that plays many frames asks
    # after each.
    def take_audio
      samples = @audio
      @audio = []
      samples
    end

    # --- the time ---

    # WHERE THE PROCESSOR'S TIME WENT since this was last asked: each address an instruction started
    # at (as 8xxxxxxxh, where a program runs), and the processor's cycles from its fetch to the next
    # instruction's, whatever it stood still for included (a copy that stops it, a wait on the
    # graphics chip). Code outside main RAM, the BIOS's, is all counted at 80000000h, where no
    # program runs. The first ask starts the count and
    # answers nothing.
    def take_processor_time
      bytes = memory(PROCESSOR_TIME)
      bytes.unpack("L<Q<" * (bytes.bytesize / 12)).each_slice(2).to_h
    end

    # HOW LONG THE GRAPHICS CHIP HAS SPENT DRAWING since power-on, in the processor's cycles. The chip
    # draws while the processor goes on, so this is time of its own: a frame whose chip was busy for
    # most of it is a frame the chip, not the processor, made long, once the processor waits for it.
    def gpu_busy_cycles = memory(GPU_BUSY).unpack1("Q<")

    # Main RAM read in place, at +address+ (only its low 21 bits matter, so 80010000h, A0010000h and
    # 00010000h are the same byte), low byte first as the console keeps a number. Each address is
    # taken within the 2 megabytes as the first is, so a read that runs past the end goes on from the
    # start, as the console's mirrors of RAM do.
    def ram_read8(address) = ram_bytes(address, 1).getbyte(0)
    def ram_read16(address) = ram_bytes(address, 2).unpack1("v")
    def ram_read32(address) = ram_bytes(address, 4).unpack1("V")
    def ram_bytes(address, count) = read_around(SYSTEM_RAM, RAM_SIZE, address, count)
    def ram_write32(address, value) = write_around(SYSTEM_RAM, RAM_SIZE, address, [value & 0xFFFF_FFFF].pack("V"))

    # The scratchpad read and written in place, +offset+ bytes from its start (1F800000h), going on
    # from its start past its end as RAM does.
    def scratchpad_bytes(offset, count) = read_around(SCRATCHPAD, SCRATCHPAD_SIZE, offset, count)
    def scratchpad_write32(offset, value) = write_around(SCRATCHPAD, SCRATCHPAD_SIZE, offset, [value & 0xFFFF_FFFF].pack("V"))

    # --- the memory card ---

    # The memory card in the first slot, all 128K of it, as the core keeps it. The core keeps it only
    # in memory and writes no file of it: a frontend that wants it kept reads it here.
    def memory_card = memory(MEMORY_CARD)

    # The memory card in the first slot, written over from its start (for a console that starts from a
    # card a frontend kept).
    def memory_card=(bytes)
      size = @frontend.memory_size(MEMORY_CARD)
      @frontend.memory_write(MEMORY_CARD, 0, bytes.byteslice(0, size)) if size.positive?
    end

    # Unloads the program, shuts the core and lets go of its library.
    def destroy
      return unless @shutdown

      ObjectSpace.undefine_finalizer(self)
      @shutdown.call
      @shutdown = nil
    end

    # A CONSOLE NOBODY DESTROYED IS SHUT BY RUBY when it collects the Core, the same way #destroy shuts
    # it. It must not be left as it is. Ruby closes the copy's lock when it collects it, and the copy is
    # handed to the next console made in this process, while the library is still open here with the
    # old program in it, never shut: the next console's start goes on top of it, and the old console's
    # memory is kept for as long as the process runs. So the frontend is closed first and the copy given
    # back after.
    #
    # The finalizer must hold nothing that holds the Core, or the Core is never collected. The
    # frontend's callbacks are C and hold nothing of Ruby's, so holding the frontend is enough.
    class Shutdown
      def initialize(frontend, copy, dir)
        @frontend = frontend
        @copy = copy
        @dir = dir
      end

      # Unloads the program, shuts the core, closes the library and gives the copy back. A finalizer is
      # handed the Core's object id, which is not needed here.
      def call(_object_id = nil)
        return unless @frontend

        @frontend.close
        @copy.give_back
        @frontend = nil
        FileUtils.rm_rf(@dir)
      end
    end

    private

    def memory(id) = @frontend.memory(id)

    # +count+ bytes of memory +id+, which is +size+ bytes (a power of two), from +offset+ taken within
    # it, going on from its start past its end.
    def read_around(id, size, offset, count)
      start = offset & (size - 1)
      before_end = [count, size - start].min
      bytes = @frontend.memory_read(id, start, before_end)
      bytes << @frontend.memory_read(id, 0, count - before_end) if count > before_end
      bytes
    end

    # +bytes+ written over memory +id+ as #read_around reads it.
    def write_around(id, size, offset, bytes)
      start = offset & (size - 1)
      before_end = [bytes.bytesize, size - start].min
      @frontend.memory_write(id, start, bytes.byteslice(0, before_end))
      @frontend.memory_write(id, 0, bytes.byteslice(before_end..)) if bytes.bytesize > before_end
    end

    # The sound the frame just played made, kept until #take_audio asks for it, and counted.
    def take_sound(bytes)
      @sound_frames += bytes.bytesize / 4
      @audio.concat(bytes.unpack("s<*"))
    end

    # Opens a copy of the core of this Core's own and starts it, with the system folder (where a BIOS
    # is linked) and the save folder it is told.
    def start_frontend(save_dir)
      copy = KeptCopy.take
      begin
        @frontend = Frontend.new(copy.path, @dir, save_dir, SETTINGS, ANY_PIXEL_FORMAT)
      rescue StandardError, LoadError
        copy.give_back
        FileUtils.rm_rf(@dir)
        raise
      end
      @shutdown = Shutdown.new(@frontend, copy, @dir)
      ObjectSpace.define_finalizer(self, @shutdown)
      refuse_unpatched_core!
    end

    def refuse_unpatched_core!
      return if @frontend.memory_size(GPU_STATE).positive?

      destroy
      raise LoadError, "#{CoreLibrary.path} is a Beetle PSX core built without this gem's probe patch, so it " \
                       "cannot hand over the console's memories. Build it with `rake compile_core` in " \
                       "ruby-ps1-emulator/."
    end

    # Hands the core the program's path and bytes, and plugs a pad into the first port.
    def load_program(exe_path)
      loaded = @frontend.load_game(File.expand_path(exe_path), File.binread(exe_path))
      raise ArgumentError, "Beetle PSX would not load #{exe_path}" unless loaded

      @frontend.set_controller_port_device(0, JOYPAD)
    end
  end
end
