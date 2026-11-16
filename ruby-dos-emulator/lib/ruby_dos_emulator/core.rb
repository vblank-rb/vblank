# frozen_string_literal: true

require "fileutils"
require "tmpdir"

module RubyDOSEmulator
  # ONE DOS MACHINE, PLAYED A FRAME AT A TIME with nobody watching: a program (an .EXE or a .COM)
  # run by DOSBox (libretro's dosbox-svn core, see CoreBuild) with the program's own folder as drive C:,
  # its keys pressed from Ruby, and everything a test wants to read back handed over as plain bytes:
  # the first megabyte of memory, the video card's memory and palette and mode, the picture shown
  # and the sound made.
  #
  #   core = RubyDOSEmulator::Core.new("GAME.EXE")
  #   core.press(%i[left ctrl])
  #   core.run_frame
  #   core.peek(0x1234, 0x10)
  #   core.destroy
  #
  # A LIBRETRO CORE IS ONE MACHINE PER LIBRARY: it keeps the whole PC in the library's own globals.
  # So each Core loads a copy of the library of its own (CoreCopy), and two Cores in one process are
  # two machines that cannot see each other.
  #
  # THE MACHINE IS SET BY A DOSBOX CONFIGURATION FILE (#configuration), which is the "game" the core
  # is loaded with. It says a Sound Blaster at 220h
  # on IRQ 5 and DMA 1, an AdLib's OPL2, a VGA card with the memory a VESA mode wants, a 486, and a
  # FIXED number of processor cycles for every millisecond, so a program runs the same on every run
  # and on every machine, whatever the host's speed. Then it mounts the program's folder and runs it.
  #
  # THE PICTURE is what DOSBox shows (#picture), as the core hands it over after each frame: 24-bit
  # colours, the palette already applied. #vga_memory and #palette are the card's own, for a check
  # that wants what the program wrote rather than what was shown.
  #
  # A FRAME IS ONE PICTURE OF THE VIDEO CARD'S. The core is asked for the timing in which the machine
  # keeps no time by the host's clock and every step ends when the card has finished drawing a picture
  # (CoreBuild says more). So #run_frame is one vertical retrace, a program that waits for the retrace
  # makes one pass in it, and what is read afterwards is the machine stopped between two pictures.
  #
  # THE FRONTEND IS IN THE CORE, NOT IN RUBY. The probe patch carries the frontend's half (the vblank_*
  # functions): it answers the core's questions, takes the keys at a moment in the machine's own time,
  # and keeps the last picture and the sound made. Machine, this gem's C extension, hands the core those
  # functions and calls them (ext/ruby_dos_emulator_ext/ruby_dos_emulator_ext.c says why that is C and
  # not Fiddle). So a Core can be made and played in any Ractor.
  class Core
    # libretro's name for system RAM, and the probe patch's own (core/dosbox-vblank-probe.patch).
    SYSTEM_RAM = 2
    VIDEO_RAM = 0x8001
    PALETTE = 0x8002
    VGA_STATE = 0x8003

    # libretro's number for a keyboard (RETRO_DEVICE_KEYBOARD), as what is plugged into the first port.
    KEYBOARD = 3

    # DOSBox's speed: processor cycles in each millisecond. 30000 is about a fast 486.
    CYCLES = 30_000

    # libretro's key numbers (RETROK_*) for the keys a DOS game is played with, by name.
    KEYS = { up: 273, down: 274, right: 275, left: 276, ctrl: 306, alt: 308, enter: 13, shift: 303,
             z: 122, x: 120, space: 32, escape: 27, left_shift: 304, left_ctrl: 306, right_ctrl: 305,
             pause: 19 }.freeze

    # The card's state: its mode (DOSBox's own numbering), the width and height it draws, and how far
    # its memory address moves on for each row.
    VGAState = Data.define(:mode, :width, :height, :address_add)

    # A frame as the core handed it over: its size and its pixels as 0xRRGGBB, row by row.
    Picture = Data.define(:width, :height, :pixels)

    attr_reader :frames

    # THE START GATE: a byte at 0040:00F2, in the 16 bytes the PC keeps free for programs to talk to each
    # other. A program started as `GAME.EXE HOLD` is meant to set it and wait for it to be cleared, so a
    # reader can see its first pass from the start: DOSBox runs the program during its own start-up, and
    # without the gate the first passes are over before a test can look. #release_gate lets it go.
    START_GATE_AT = 0x4F2

    # +program+ is the path of an .EXE or a .COM; its folder is drive C: (a copy of it, so a program
    # that saves a file never changes what is on disk; read it back with #drive_file). With +in_place+
    # the folder itself is the drive, and a file the program writes is there once the machine is shut.
    # With +hold+ the program is started with the word HOLD after its name (see START_GATE_AT).
    def initialize(program, hold: false, in_place: false)
      @hold = hold
      @dir = Dir.mktmpdir("ruby-dos-emulator")
      @drive = in_place ? File.dirname(File.expand_path(program)) : copied_folder_of(program)
      @frames = 0
      @held = []
      start(File.basename(program))
    end

    # The keys held down, by name (KEYS), from the next frame on.
    def press(keys)
      unknown = keys - KEYS.keys
      raise ArgumentError, "a DOS keyboard has no #{unknown.join(', ')} key here" unless unknown.empty?

      codes = keys.map { |key| KEYS.fetch(key) }
      (@held - codes).each { |code| @machine.key_event(false, code) }
      (codes - @held).each { |code| @machine.key_event(true, code) }
      @held = codes
    end

    # Plays one frame: until the video card has finished its next picture, about a seventieth of a second
    # in mode 13h. The machine is stopped when this returns, so everything read after it is what the
    # program had done by the end of that picture, whatever the host's speed.
    def run_frame
      @machine.run
      @frames += 1
      self
    end

    # How many pictures the card draws in a second, as the core last said it: the core says a new mode's
    # rate at the start of the frame after the one that set the mode.
    def fps = timing.first

    # How many pairs of samples #take_audio gives for a second of sound.
    def sample_rate = timing.last

    # The PC's clock chip reads +time+ whenever a program asks it, the date and the hour +time+ shows,
    # from now until the machine is shut; +kept+ is whether its battery kept the time, which the chip
    # says too. A machine never told reads the host's clock. Tell it before the first frame, since a
    # program reads the clock as it starts.
    def clock_at(time, kept: true)
      @machine.clock_at(time.year, time.month, time.day, time.hour, time.min, time.sec, time.wday, kept)
      self
    end

    # Whether the program has reached its gate and is waiting there (see START_GATE_AT).
    def gate_closed? = peek(START_GATE_AT, 1).getbyte(0) == 1

    # Lets a program held at its start go on.
    def release_gate = poke(START_GATE_AT, "\0")

    # --- the picture ---

    # The last picture the core handed over (a Picture), or nil before the first.
    def picture
      bytes, wide, high = @machine.picture
      return nil unless bytes

      Picture.new(width: wide, height: high, pixels: bytes.unpack("V*").map { |pixel| pixel & 0xFF_FFFF })
    end

    # --- the memories ---

    # +count+ bytes of the PC's first megabyte, from linear address +address+ (segment * 16 + offset).
    def peek(address, count) = @machine.memory_read(SYSTEM_RAM, address, count)

    # Writes +bytes+ into the PC's first megabyte at linear address +address+, as a program's own store would.
    def poke(address, bytes) = @machine.memory_write(SYSTEM_RAM, address, bytes)

    # The video card's memory as DOSBox keeps it: four planes interleaved (byte 4n + plane). A mode
    # that is unchained (Mode X) reads that as it is. Mode 13h is chained, and DOSBox spreads its
    # pixels over the planes four at a time, 16 bytes apart (see #chained_pixels).
    def vga_memory = memory(VIDEO_RAM)

    # The first +count+ pixels of a chained mode (mode 13h) as one palette index each, in screen order.
    # Pixel n is at byte ((n >> 2) << 4) + (n & 3) of the card's memory: the card's address n goes to
    # plane (n & 3), at plane address (n >> 2), and a plane's byte is 4 bytes in DOSBox's memory.
    def chained_pixels(count = 64_000)
      memory = vga_memory
      Array.new((count + 3) / 4) { |group| memory.byteslice(group * 16, 4) }.join.byteslice(0, count)
    end

    # The 256 colours of the card's palette as [red, green, blue], each of 6 bits as the card keeps them.
    def palette = memory(PALETTE).unpack("C*").each_slice(3).to_a

    # The card's state now (a VGAState).
    def vga_state = VGAState.new(*memory(VGA_STATE).unpack("L<4"))

    # --- the sound ---

    # The sound made since this was last asked: pairs of signed 16-bit samples as [left, right], at
    # #sample_rate a second.
    def take_audio = @machine.take_sound.unpack("s<*").each_slice(2).to_a

    # --- the files ---

    # What a program saved on drive C: (its name in capitals, as DOS keeps it), or nil.
    def drive_file(name)
      found = Dir.children(@drive).find { |child| child.casecmp?(name) }
      found && File.binread(File.join(@drive, found))
    end

    # Unloads the program, shuts the core and lets go of its library, and the machine's memory with it.
    def destroy
      return unless @machine

      @machine.close
      release
    end

    private

    def copied_folder_of(program)
      drive = File.join(@dir, "c")
      FileUtils.mkdir_p(drive)
      FileUtils.cp_r(File.join(File.dirname(File.expand_path(program)), "."), drive)
      drive
    end

    # Opens a copy of the core of its own and starts the machine on +program+. A machine that cannot
    # start leaves nothing behind: not its library, and not its folder.
    def start(program)
      copy = CoreCopy.make
      @machine = Machine.new(copy.path, @dir)
      load_program(program)
      # The core asks for key presses when it is told what is plugged in, which it can only take once it has a machine.
      @machine.set_controller_port_device(0, KEYBOARD)
    rescue Machine::Unpatched
      release
      raise LoadError, CoreLibrary.unpatched_message(CoreLibrary.path)
    rescue StandardError, LoadError
      release
      raise
    ensure
      copy&.delete
    end

    def release
      @machine&.close
      @machine = nil
      FileUtils.rm_rf(@dir)
    end

    def memory(id) = @machine.memory(id)

    # The DOSBox configuration this machine is made from (see the comment atop this class).
    def configuration(program)
      <<~CONF
        [dosbox]
        machine=svga_s3
        memsize=4
        [render]
        aspect=false
        scaler=none
        frameskip=0
        [cpu]
        core=normal
        cputype=486
        cycles=fixed #{CYCLES}
        [mixer]
        rate=44100
        [sblaster]
        sbtype=sb2
        sbbase=220
        irq=5
        dma=1
        oplmode=opl2
        [autoexec]
        @echo off
        mount c "#{@drive}"
        c:
        #{program}#{' HOLD' if @hold}
      CONF
    end

    # The machine is loaded with its configuration file, as libretro loads a game by its path.
    def load_program(program)
      path = File.join(@dir, "machine.conf")
      File.write(path, configuration(program))
      raise ArgumentError, "DOSBox would not load #{program}" unless @machine.load_game(path)
    end

    # The frame rate and the sound's rate, asked each time, since the frame rate is the mode's.
    def timing = @machine.timing
  end
end
