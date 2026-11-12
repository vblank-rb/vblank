# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "stringio"

# EACH SCENE BRINGS ITS OWN RECORDINGS INTO THE SOUND CHIP. The Super Nintendo's sound chip plays
# recordings only from its own 64K of memory, which the console fills through four one-byte
# mailboxes. A game whose recordings come to more than that still builds when no one scene plays
# more than fits: what every scene can play stays in the chip from power-on, and each scene's own
# go in as it takes over, over the scene before's. The checked run holds every pass to the
# interpreter; the chip's memory (CheckedRun#apu_ram) says which recordings are in it.
class TestSNESSceneRecordings < Minitest::Test
  SNES = VBlank::IR::Backends::SNES
  Samples = SNES::Samples
  VOICE = 4 << 4 # The voice the first recording plays on
  SRCN = 0x4     # A voice's register numbering the table row it plays
  DIR = 0x5D     # The DSP register naming the table's page
  ENVX = 0x8     # A voice's register holding how loud its envelope is now

  # Two recordings of 64000 samples, 36000 bytes each in the chip's format: 72000 together, against
  # 64704 the chip has room for, but either fits alone. Each is a pattern of its own, so the bytes in
  # the chip's memory say which one is there.
  LENGTH = 64_000
  HALL = Array.new(LENGTH) { |i| ((i % 32) - 16) * 4 }.pack("c*")
  CAVE = Array.new(LENGTH) { |i| ((i % 20) < 10 ? 48 : -48) }.pack("c*")
  # One recording every scene plays, which stays in the chip throughout.
  CHIME = Array.new(320) { |i| ((i % 16) - 8) * 8 }.pack("c*")

  HALL_STARTS = 3      # The pass the hall plays its echo on
  CAVE_TAKES_OVER = 30
  CAVE_STARTS = 32     # The pass the cave plays its drip on
  # Frames of the console's from power-on, for the cartridge read with no build record: the hall's
  # recording goes across before the first pass, and the cave's as the cave takes over, each some
  # fifty frames, so the first reading is inside the hall's passes and the second well after the cave's.
  HALL_FRAMES = 70
  CAVE_FRAMES = 190

  private def game(hall: HALL, cave: CAVE)
    b = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: :snes))
    TestSNESSceneRecordings.declare(b, hall: hall, cave: cave)
    b.finalize_program
    b.program
  end

  # The game, declared into +builder+: a hall and a cave, each with a recording of its own, and a
  # chime both play.
  def self.declare(builder, hall: HALL, cave: CAVE)
    builder.instance_eval do
      enable_sound
      echo = sample :hall_echo, pcm: hall, rate: 32_000
      drip = sample :cave_drip, pcm: cave, rate: 32_000
      chime = sample :chime, pcm: CHIME, rate: 32_000
      state = var :state, 0
      step = var :step, 0
      scene(:hall) do
        echo.play(loop: true) if step == HALL_STARTS
        chime.play if step == HALL_STARTS + 1
      end
      scene(:cave) do
        drip.play(loop: true) if step == CAVE_STARTS
        chime.play if step == CAVE_STARTS + 1
      end
      game_loop do
        step += 1
        state = 1 if step == CAVE_TAKES_OVER
        case_var(:state) do
          when_val 0, :hall
          when_val 1, :cave
        end
      end
    end
  end

  # The bytes the voice playing +voice+ reads, from the start of its row of the chip's table.
  private def bytes_heard(run, voice, count)
    ram = run.apu_ram
    dsp = run.dsp_registers
    row = (dsp.getbyte(DIR) << 8) + (dsp.getbyte(voice + SRCN) * 4)
    start = ram.byteslice(row, 2).unpack1("v")
    ram.byteslice(start, count).bytes
  end

  private def kept(pcm) = Samples.recording(pcm, LENGTH).first

  def test_the_first_scene_plays_its_own_recording_from_the_chips_memory
    run = SNES::CheckedRun.new.run(game, frames: HALL_STARTS + 3)

    assert_equal %i[hall_echo], run.active_samples
    assert_equal kept(HALL), bytes_heard(run, VOICE, kept(HALL).size)
  end

  def test_the_next_scene_brings_its_own_recording_in_over_the_first
    run = SNES::CheckedRun.new.run(game, frames: CAVE_STARTS + 4)

    assert_includes run.active_samples, :cave_drip
    drip_voice = (4..7).map { |voice| voice << 4 }.find { |voice| bytes_heard(run, voice, 9) == kept(CAVE).first(9) }

    refute_nil drip_voice, "no voice reads the cave's recording"
    assert_equal kept(CAVE), bytes_heard(run, drip_voice, kept(CAVE).size)
  end

  # The chime both scenes play went across at power-on and is still there in the cave, played from
  # where it always was.
  def test_a_recording_every_scene_plays_stays_in_the_chip
    run = SNES::CheckedRun.new.run(game, frames: CAVE_STARTS + 4)
    chime = Samples.recording(CHIME, 0).first

    assert_includes run.audio, [:sample, :chime]
    ram = run.apu_ram
    assert ram.bytes.each_cons(chime.size).any?(chime), "the chime is not in the chip's memory"
  end

  # The cartridge read as a file with no build record, as a port reads its own (Verifier#sound_ram):
  # while the hall is up its echo is in the chip and the cave's drip is not, and once the cave has
  # taken over the drip is there, in the same place, and the echo is gone.
  def test_the_sound_ram_holds_the_scene_ups_recordings_alone
    cartridge = VBlank.build("SCENESOUND", console: :snes, out: nil, err: nil) { TestSNESSceneRecordings.declare(self) }
    Dir.mktmpdir("cartridges") do |folder|
      path = File.join(folder, "scene_sound.sfc").tap { |file| cartridge.write(file) }
      VBlank::Playthroughs::Probe.open(path) do |probe|
        probe.step(HALL_FRAMES)
        hall = probe.reader.sound_ram
        probe.step(CAVE_FRAMES - HALL_FRAMES)
        cave = probe.reader.sound_ram

        assert_equal [true, false], [hall.include?(kept(HALL).pack("C*")), hall.include?(kept(CAVE).pack("C*"))]
        assert_equal [false, true], [cave.include?(kept(HALL).pack("C*")), cave.include?(kept(CAVE).pack("C*"))]
        assert_equal hall.index(kept(HALL).pack("C*")), cave.index(kept(CAVE).pack("C*"))
      end
    end
  end

  # The hall's echo is still sounding as the cave takes over, and the cave's recording goes in over
  # it, so the chip lets that voice go first: it is silent (ENVX nought) once the cave is up, while
  # the interpreter's count of the echo runs on, the checked run holding the cartridge's to it.
  def test_a_voice_reading_the_scene_befores_recording_is_let_go
    run = SNES::CheckedRun.new.run(game, frames: CAVE_TAKES_OVER + 2)

    assert_includes run.active_samples, :hall_echo
    assert_equal 0, run.dsp_registers.getbyte(VOICE + ENVX)
  end

  # WHAT A SCENE CHANGE COSTS: the cave's 36000 bytes go across in the pass the cave takes over on,
  # three bytes a turn of the mailboxes (Runtime::Sound::BYTES_A_FRAME); every other pass keeps its frame.
  MOST_FRAMES_TO_LOAD_THE_CAVE = 55

  def test_the_pass_the_cave_takes_over_on_runs_long_by_its_load_alone
    run = SNES::HeadlessRun.new.run(game, frames: CAVE_TAKES_OVER + 4)
    long = (1..CAVE_TAKES_OVER + 3).select { |pass| run.frames_took(pass) > 1 }

    assert_equal 1, long.size, "passes that ran long: #{long.inspect}"
    assert_operator run.frames_took(long.first), :<=, MOST_FRAMES_TO_LOAD_THE_CAVE
  end

  # The build says what a scene change costs, since nothing else shows it: the cave's 36000 bytes take
  # some fifty frames to go across.
  def test_the_build_says_how_long_a_scenes_recordings_take_to_send
    said = StringIO.new
    VBlank.build("SCENESOUND", console: :snes, out: nil, err: said) { TestSNESSceneRecordings.declare(self) }

    assert_match "scene :cave", said.string
    assert_match "36000 bytes", said.string
  end

  # One scene whose own recordings do not fit is refused, naming it and the sizes.
  def test_a_scene_whose_recordings_do_not_fit_is_refused_naming_it
    error = assert_raises(VBlank::BuildError) { SNES.new.build(game(cave: CAVE * 2)) }

    assert_match "scene :cave", error.message
    assert_match "sound memory", error.message
  end
end
