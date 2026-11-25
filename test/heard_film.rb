# frozen_string_literal: true

require "json"
require "open3"

# The sound of a film read back (Diagnostics::FilmSound), for the film's, the film tasks' and the
# film shell's tests: each speaker's loudness on each of the film's frames, and where a sound
# starts. Decoded by ffmpeg, so a test including it runs on the main Ractor.
module HeardFilm
  # The film's sound, each speaker's loudness on each of the film's frames: its samples added up
  # without their signs, a sixtieth of a second at a time.
  private def film_sound(path)
    raw, status = Open3.capture2("ffmpeg", "-v", "error", "-i", path, "-map", "0:a", "-f", "s16le", "-ac", "2",
                                 "-ar", "48000", "-", binmode: true)
    assert status.success?, "ffmpeg decoded the sound of #{path}"
    samples = raw.unpack("s<*")
    [0, 1].map { |speaker| samples.each_slice(2).map { |pair| pair[speaker].abs }.each_slice(800).map(&:sum) }
  end

  # The film's sound streams, each with how many speakers it has.
  private def audio_streams(path)
    json, status = Open3.capture2("ffprobe", "-v", "error", "-select_streams", "a", "-show_entries", "stream=channels",
                                  "-of", "json", path)
    assert status.success?, "ffprobe read #{path}"
    JSON.parse(json).fetch("streams")
  end

  # The first of +energies+ louder than a tenth of the loudest.
  private def onset(energies)
    loudest = energies.max
    assert_operator loudest, :>, 0, "nothing was heard"
    energies.index { |energy| energy > loudest / 10 }
  end

  # A game that sounds a tone that does not fade from pass +beep_on+, and paints red and blue by turns.
  private def beeping_game_source(beep_on)
    proc do
      enable_sound
      shade = var :shade, 0
      game_loop do
        shade += 1
        beep 440, decay: :none if shade == beep_on
        clear_screen(:red) if shade % 2 == 1
        clear_screen(:blue) if shade % 2 == 0
      end
    end
  end
end
