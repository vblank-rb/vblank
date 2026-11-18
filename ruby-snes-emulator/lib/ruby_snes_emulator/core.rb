# frozen_string_literal: true

require "fileutils"
require "tmpdir"

module RubySNESEmulator
  # ONE SUPER NINTENDO, PLAYED A FRAME AT A TIME with nobody watching: a cartridge loaded into
  # bsnes (a libretro core, see CoreLibrary), its buttons set from Ruby, and everything a test
  # wants to read back handed over as plain bytes — the picture of the last frame, the work RAM,
  # the video RAM, the colour memory, the sprite table, the processor's registers and the
  # cartridge's battery-backed RAM.
  #
  #   core = RubySNESEmulator::Core.new("game.sfc")
  #   core.set_buttons(%i[right])
  #   core.run_frame
  #   core.wram_read8(0x0100)
  #   core.destroy
  #
  # A LIBRETRO CORE IS ONE CONSOLE PER LIBRARY: it keeps the whole machine in the library's own
  # globals. So each Core loads a copy of the library of its own (KeptCopy), and two Cores in one
  # process are two consoles that cannot see each other. The copy is loaded with its names kept
  # to itself (no RTLD_GLOBAL), or the second copy's code would call into the first's. Closing it
  # lets go of those globals, so a Core made later from the same copy is a console just out of
  # the box.
  #
  # The core is played through Frontend, this gem's C extension: it opens the copy, answers what
  # the core asks, and keeps the picture and the sound the core hands over until they are asked
  # for here (ext/ruby_snes_emulator_ext/libretro_frontend.c says why that is C). So a Core can be
  # made and played in any Ractor.
  class Core
    # libretro's names for the memories, and the probe patch's own (core/bsnes-vblank-probe.patch).
    SAVE_RAM = 0
    SYSTEM_RAM = 2
    VIDEO_RAM = 3
    CGRAM = 0x8001
    OAM = 0x8002
    REGISTERS = 0x8003
    APU_RAM = 0x8004
    DSP_REGISTERS = 0x8005
    MANIFEST = 0x8006
    PROCESSOR_TIME = 0x8007
    OBSEL = 0x8008

    # libretro's joypad: the number it asks about each button by.
    BUTTONS = { b: 0, y: 1, select: 2, start: 3, up: 4, down: 5, left: 6, right: 7,
                a: 8, x: 9, l: 10, r: 11 }.freeze

    # The settings the core asks for, as libretro names them. The PPU and the sound DSP are the
    # accurate ones — the fast PPU keeps its memories elsewhere, and the probe reads the accurate
    # one's — and nothing is run ahead.
    SETTINGS = Ractor.make_shareable({ "bsnes_ppu_fast" => "OFF", "bsnes_dsp_fast" => "OFF",
                                       "bsnes_run_ahead_frames" => "OFF", "bsnes_ppu_show_overscan" => "OFF",
                                       "bsnes_cpu_fastmath" => "OFF", "bsnes_hotfixes" => "OFF",
                                       "bsnes_entropy" => "None" })

    # libretro's picture format of four bytes a pixel, the one bsnes is let draw in.
    XRGB8888 = 1

    JOYPAD = 1

    # The console's picture: 256 pixels across and 224 lines down, the lines a television showed
    # of a game that does not ask for the taller 239.
    WIDTH = 256
    HEIGHT = 224

    # Work RAM's size: banks $7E and $7F.
    WORK_RAM_SIZE = 0x20000

    attr_reader :frames, :drawn_width, :drawn_height

    # +rom_path+ is the cartridge; its battery-backed RAM is kept in a .srm file in +save_dir+,
    # read when the cartridge is loaded and written when the core is destroyed. Without
    # +save_dir+ the file goes in a folder of the core's own that is gone with it.
    def initialize(rom_path, save_dir: nil)
      @dir = Dir.mktmpdir("ruby-snes-emulator")
      @frames = 0
      @picture = nil
      @drawn_width = WIDTH * 2
      @drawn_height = HEIGHT * 2
      @audio = []
      start_frontend(save_dir || @dir)
      load_cartridge(rom_path)
    end

    # The buttons down on controller +port+ (0 for the first), by name (BUTTONS).
    def set_buttons(buttons, port: 0)
      unknown = buttons - BUTTONS.keys
      raise ArgumentError, "a Super Nintendo controller has no #{unknown.join(', ')} button" unless unknown.empty?

      @frontend.set_buttons(port, buttons.sum { |button| 1 << BUTTONS.fetch(button) })
    end

    # Plays one frame: up to the moment the console starts its next picture.
    def run_frame
      @frontend.run
      @audio << @frontend.drain_audio
      update_picture
      @frames += 1
      self
    end

    # The last frame's picture as bsnes drew it: drawn_width × drawn_height pixels, four bytes
    # each — blue, green, red and one unused — row by row. The accurate PPU always draws a frame
    # twice the console's size each way, so that its high-resolution and interlaced modes fit;
    # a game in neither has each of its pixels drawn as a square of four.
    def video_buffer = @picture || ("\0".b * (@drawn_width * @drawn_height * 4))

    # The last frame's picture as the console's own colours, at the console's own size (#width
    # × #height): a 15-bit number for each pixel, red in the low five bits, then green, then blue,
    # as the colour memory keeps them. Of each square of four bsnes drew, the top-left is taken.
    def width = WIDTH
    def height = HEIGHT

    #
    # A picture that has not changed since the last one asked for is the same list again: most
    # frames of a game change little, and comparing the bytes is far quicker than turning them
    # into colours. So the list must not be changed by whoever is given it.
    def colors
      return @colors if @colors && @colors_of == video_buffer

      @colors_of = video_buffer
      @colors = Core.picture_colors(video_buffer, @drawn_width, @drawn_height).freeze
    end

    # +buffer+, a picture bsnes drew at +drawn_width+ × +drawn_height+ (#video_buffer), as the
    # console's own colours at its own size (#colors). Public for the gem's own test, which holds it
    # to the arithmetic pixel by pixel on a picture no cartridge would draw.
    #
    # ONE UNPACK AND ONE LOOKUP, NOT A BLOCK PER PIXEL. A single pattern reads the whole picture:
    # each kept row starts at its own byte (@) and is read as one number per square, the whole
    # square's width at once (a pixel, V, or two side by side, Q), so the pixels in between are
    # never made into numbers of their own. The square's top-left pixel is that number's low four
    # bytes, all #console_color looks at. A picture has few distinct squares, so a hash works out
    # each the first time it is asked for and answers every other square from memory.
    def self.picture_colors(buffer, drawn_width, drawn_height)
      colors = Hash.new { |known, square| known[square] = console_color(square) }
      colors.values_at(*buffer.unpack(picture_pattern(drawn_width, drawn_height)))
    end

    # The unpack pattern #picture_colors reads a picture of this size with. A row read as one
    # directive and a count is parsed once; a directive per pixel is parsed a pixel at a time,
    # which is most of the work. So a square two pixels wide is one 8-byte number, and only some
    # other width falls back to a pixel and a skip each.
    def self.picture_pattern(drawn_width, drawn_height)
      across = drawn_width / WIDTH
      down = drawn_height / HEIGHT
      row = case across
            when 1 then "V#{WIDTH}"
            when 2 then "Q<#{WIDTH}"
            else "Vx#{(across - 1) * 4}" * WIDTH
            end
      Array.new(HEIGHT) { |y| "@#{y * down * drawn_width * 4}#{row}" }.join
    end

    # A square as bsnes drew its top-left pixel in the low four bytes (blue, green, red, unused)
    # as a 15-bit colour: the top five bits of each, red lowest.
    def self.console_color(square)
      ((square >> 19) & 0x1F) | (((square >> 11) & 0x1F) << 5) | (((square >> 3) & 0x1F) << 10)
    end

    # The sound of the frames since this was last asked, as signed 16-bit samples, left and right
    # by turns, at 48000 samples a second for each side.
    def take_audio
      samples = @audio.join.unpack("s<*")
      @audio.clear
      samples
    end

    # WHERE THE PROCESSOR'S TIME WENT since this was last asked: each address an instruction started
    # at, as its bank × 0x10000 plus its address, and the master clocks spent there, whatever it
    # stood still for included, so a copy to video memory is charged to the line that started it. A
    # scanline is 1364 of them. The first ask starts the count and answers nothing.
    def take_processor_time
      bytes = memory(PROCESSOR_TIME)
      bytes.unpack("L<Q<" * (bytes.bytesize / 12)).each_slice(2).to_h
    end

    # --- the memories ---

    def wram = memory(SYSTEM_RAM)
    def vram = memory(VIDEO_RAM)
    def cgram = memory(CGRAM)
    def oam = memory(OAM)
    def save_ram = memory(SAVE_RAM)

    # OBSEL ($2101) as the cartridge last wrote it, which the console cannot read back: the two
    # sizes its sprites come in (the top three bits), then where their tiles are in video RAM.
    def obsel = memory(OBSEL).getbyte(0)

    # THE SOUND UNIT, which the console's own processor cannot see: the 64K the SPC700 runs its
    # program from and keeps its recorded sounds in, and the S-DSP's 128 registers, which say what
    # each of its eight voices is playing — the sound as it was told to sound, not as it was mixed.
    def apu_ram = memory(APU_RAM)
    def dsp_registers = memory(DSP_REGISTERS)

    # HOW BSNES TOOK THE CARTRIDGE: the manifest its heuristics wrote from the cartridge's header (its
    # text: the board, the ROM and RAM and where each is mapped), and the board's name from it, such
    # as "LOROM-RAM" — the ground truth for which hardware the header asks for.
    def manifest = memory(MANIFEST).force_encoding(Encoding::UTF_8)
    def board = manifest[/^\s*board:\s*(\S+)/, 1]

    # The 65816's registers: pc (bank and address, 24 bits), a, x, y, s, d, db, p, and whether
    # it is in emulation mode.
    def registers
      bytes = memory(REGISTERS)
      pc = bytes.getbyte(0) | (bytes.getbyte(1) << 8) | (bytes.getbyte(2) << 16)
      a, x, y, s, d = bytes.byteslice(3, 10).unpack("v5")
      { pc: pc, a: a, x: x, y: y, s: s, d: d, db: bytes.getbyte(13), p: bytes.getbyte(14), e: bytes.getbyte(15) == 1 }
    end

    # Work RAM read and written in place, at +address+ from 0 to 0x1FFFF (bank $7E's first byte
    # is 0, bank $7F's is 0x10000), lowest byte first as the console keeps a number. Each address
    # is taken within the 128K as the first is, so a read that runs past the end of bank $7F goes
    # on from bank $7E's first byte.
    def wram_read8(address) = wram_bytes(address, 1).getbyte(0)
    def wram_read16(address) = wram_bytes(address, 2).unpack1("v")
    def wram_read32(address) = wram_bytes(address, 4).unpack1("V")

    def wram_bytes(address, count)
      start = address & 0x1FFFF
      within = [count, WORK_RAM_SIZE - start].min
      bytes = @frontend.memory_read(SYSTEM_RAM, start, within)
      within == count ? bytes : bytes + wram_bytes(0, count - within)
    end

    def wram_write8(address, value) = @frontend.memory_write(SYSTEM_RAM, address & 0x1FFFF, [value & 0xFF].pack("C"))
    def wram_write32(address, value) = @frontend.memory_write(SYSTEM_RAM, address & 0x1FFFF, [value & 0xFFFFFFFF].pack("V"))

    # +count+ bytes of the cartridge's RAM from +address+, read in place. On a board with a chip
    # (a Super FX) that RAM is the chip's. A read past its end reads what there is.
    def save_ram_bytes(address, count)
      size = @frontend.memory_size(SAVE_RAM)
      return nil if address > size

      @frontend.memory_read(SAVE_RAM, address, [count, size - address].min)
    end

    # The cartridge's battery-backed RAM, written over (for a save that starts with something in it).
    def save_ram=(bytes)
      size = @frontend.memory_size(SAVE_RAM)
      raise ArgumentError, "this cartridge has no battery-backed RAM" if size.zero?

      @frontend.memory_write(SAVE_RAM, 0, bytes.byteslice(0, size))
    end

    # Unloads the cartridge (writing its .srm), shuts the core and lets go of its library.
    def destroy
      return unless @shutdown

      ObjectSpace.undefine_finalizer(self)
      @shutdown.call
      @shutdown = nil
    end

    # A CONSOLE NOBODY DESTROYED IS SHUT BY RUBY when it collects the Core, the same way #destroy
    # shuts it. It must not be left as it is. Ruby closes the copy's lock when it collects it,
    # and the copy is handed to the next console made in this process, while the library is
    # still open here with the old cartridge in it. bsnes takes a cartridge still in the console
    # out as the next one goes in, and writes its RAM to the new cartridge's save file, which the
    # new one then reads: the new console starts from the old one's save. So the frontend is
    # closed first and the copy given back after.
    #
    # The finalizer must hold nothing that holds the Core, or the Core is never collected. The
    # frontend's callbacks are C and hold nothing of Ruby's, so holding the frontend is enough.
    class Shutdown
      def initialize(frontend, copy, dir)
        @frontend = frontend
        @copy = copy
        @dir = dir
      end

      # Takes the cartridge out (writing its .srm), shuts the core, closes the library and gives
      # the copy back. A finalizer is handed the Core's object id, which is not needed here.
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

    # Opens a copy of the core of this Core's own and starts it, keeping the picture to the format
    # #picture_colors reads.
    def start_frontend(save_dir)
      copy = KeptCopy.take
      begin
        @frontend = Frontend.new(copy.path, @dir, save_dir, SETTINGS, XRGB8888)
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
      return if @frontend.memory_size(REGISTERS) == 16

      destroy
      raise LoadError, "#{CoreLibrary.path} is a bsnes core built without this gem's probe patch, so it cannot hand " \
                       "over the console's memories. Build it with `rake compile_core` in ruby-snes-emulator/."
    end

    # The picture handed over by the frame just played, if there was one. A frame the core drew
    # nothing new for keeps the last.
    def update_picture
      bytes, width, height = @frontend.drain_picture
      return unless bytes

      @drawn_width = width
      @drawn_height = height
      @picture = bytes
    end

    # libretro's retro_game_info: the path and the bytes.
    def load_cartridge(rom_path)
      loaded = @frontend.load_game(File.expand_path(rom_path), File.binread(rom_path))
      raise ArgumentError, "bsnes would not load #{rom_path}" unless loaded

      @frontend.set_controller_port_device(0, JOYPAD)
    end
  end
end
