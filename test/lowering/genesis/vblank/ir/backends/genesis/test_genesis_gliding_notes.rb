# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# A recorded note that glides, heard from the Genesis's cartridge in Genesis Plus GX. The checked run
# holds the 68000's count of where the recording has got to against the interpreter's; this hears that
# the sound processor took the new step too (Runtime::Recordings, GLIDE_ENTRY). A recording that lasts
# 40 frames at its own pitch is struck, and either goes on as it is or, 18 frames in, glides an octave
# up, reading the rest twice as fast: the glided one falls silent sooner, by half what was left. A sound
# processor that let the glide go by would play it to its end at the old pitch.
class TestGenesisGlidingNotes < Minitest::Test
  Score = VBlank::Audio::Score
  ROOT = VBlank::Audio::Music::NOTE_FREQUENCIES.fetch(:C4)
  RATE = 8000
  FRAMES = 40
  # Loud enough to be the recording, past the emulator's own hum.
  HEARD_ABOVE = 2000

  private def song_cartridge(glides:)
    notes = if glides
              [Score::Note.new(at: 0, hz: ROOT), Score::Note.new(at: 3, hz: ROOT * 2, length: 20, glides: true)]
            else
              [Score::Note.new(at: 0, hz: ROOT, length: 23)]
            end
    VBlank.build("GLIDES", console: :genesis, out: nil, err: nil) do
      enable_sound
      instrument :tone, pcm: [90, -90] * (RATE * FRAMES / 60 / 2), rate: RATE, note: :C4
      music = songs :music, [Score.new(parts: [Score::Part.new(plays: :tone, notes: notes)], tempo: 150, ticks_per_beat: 4,
                                       plays_once: true)]
      pass = var :pass, 0
      game_loop do
        pass += 1
        music.play 0 if pass == 20
      end
    end
  end

  # The last frame the recording is heard on, playing a frame at a time.
  private def last_heard_frame(cartridge)
    Dir.mktmpdir("cartridges") do |folder|
      path = File.join(folder, "glides.md")
      cartridge.write(path)
      VBlank::Playthroughs::Probe.open(path) do |probe|
        last = nil
        (1..120).each do |frame|
          probe.step(1)
          last = frame if frame > 20 && probe.last_frame_sound.loudest > HEARD_ABOVE
        end
        last
      end
    end
  end

  def test_the_sound_processor_reads_a_glided_note_faster_from_where_it_was
    steady = last_heard_frame(song_cartridge(glides: false))
    glided = last_heard_frame(song_cartridge(glides: true))

    assert steady, "the steady note is heard"
    assert glided, "the glided note is heard"
    assert_operator glided, :<, steady - 5
  end
end
