# frozen_string_literal: true

module VBlank
  module IR
    # Which tunes a program plays, and how each part of one plays — worked out here, once, for
    # every backend.
    #
    # It lives in one place because the answer is a promise the backends make to each other.
    # Counted two ways, the interpreter would play a note the console does not, and only in the
    # one moment that decides it — the end of a song, a part with no room to sound.
    module Tunes
      # How loud the music plays right now, as a variable the game writes and the player reads
      # at the start of each frame — the same arrangement as the tune it names. It runs 0 to
      # FULL_LEVEL, and a part sounds at its written volume times that, over FULL_LEVEL. A
      # program that never writes `music_volume` has no such variable, and plays every part at
      # its written volume with nothing worked out at all.
      #
      # Sixteen steps and not a hundred because a console voice's volume has sixteen (0..15), so
      # a finer level would only round to the same volume there. FULL_LEVEL being a power of two is
      # what lets #scaled_volume divide by it with a shift.
      LEVEL = :__music_level
      FULL_LEVEL = 16
      LEVEL_SHIFT = 4 # FULL_LEVEL is 1 << this

      # `music_volume` as the game writes and reads it: 0 to this, a percentage of FULL_LEVEL.
      FULL_PERCENT = 100

      # The loudness a recorded part's voice plays at when its written volume is 15. A mixer
      # voice's loudness runs 0 to this, where a console voice's runs 0 to 15.
      MIX_FULL = VBlank::Audio::Sound::MIX_LEVELS.fetch(:full)

      module_function

      # A written volume (0..15) — or a mixer voice's loudness — at +level+: multiplied and shifted
      # back down, so it is whole numbers on every backend and never rounds up past what was
      # written.
      def scaled_volume(volume, level) = (volume * level) >> LEVEL_SHIFT

      # A level kept 0..FULL_LEVEL as the percentage `music_volume` reads back, rounded down.
      def percent_of(level) = level * FULL_PERCENT / FULL_LEVEL

      # A part's written volume, 0..15 like the console voices', as a mixer voice's loudness. A
      # recorded note's volume can hold a fraction (Score::Note), which is how a note gets a
      # loudness between two whole volumes: 15 x L / 512 is L exactly. Worked out as an exact
      # fraction so a Float and a Rational of the same value come out the same.
      def mix_loudness(volume) = (volume.to_r * MIX_FULL / 15).round

      # The songs the program can play, in the order they are declared: every song it names with
      # `play_song`, and every song in a list it picks from by number. A song that is written and
      # never played takes nothing.
      def played_songs(program)
        names = program.walk.filter_map { |node| node.name if node.kind == :play_song }
        names += lists_played(program).values.flatten
        program.walk.select { |node| node.kind == :song && names.include?(node.name) }
      end

      # Every song the program declares, once each, in the order declared: the order the C,
      # JavaScript and Ruby runtimes and every cartridge but the Advance's number them by, which is
      # how a reader of a running game turns the number a player keeps back into the song's name.
      def declared_songs(program) = program.walk.select { |node| node.kind == :song }.uniq(&:name)

      # The name of the song a player keeps as +number+, its place in #declared_songs counted from
      # 1, or nil for nought (no song).
      def song_numbered(program, number) = number.zero? ? nil : declared_songs(program).fetch(number - 1).name

      # Each song list the program picks from by number, with its songs in order.
      def lists_played(program)
        picked = program.walk.filter_map { |node| node.name if node.kind == :play_from_list }.uniq
        program.walk.select { |node| node.kind == :song_list && picked.include?(node.name) }
               .to_h { |node| [node.name, node.songs] }
      end

      # Every instrument a song names — for its parts, and for any note that names its own.
      def instruments(song)
        soundings(song).map(&:name).uniq
      end

      # What one note sounds: the recording it plays, and the envelope that shapes how it starts
      # and ends. The two travel together because they are one thing to a sounding voice, and
      # keeping them together is what makes an envelope free per note: two notes on the same
      # recording shaped differently are two of these, each gets its own entry in the score's
      # table of recordings, and a note names an entry by the number it already carried.
      #
      # A nil envelope is "whatever the recording itself was declared with", which only the
      # backend knows, since it is the one holding the declarations.
      Sounding = Data.define(:name, :envelope)

      # Every sounding a song asks for. A note's own instrument and envelope win over the part's,
      # and the part's own pairing is here too, for a part whose notes all set nothing.
      #
      # A part that reads its notes from the file the program is handed as it starts
      # (StartFile::Notes) has no events yet: any of the instruments it names may sound, each
      # shaped as the part is.
      def soundings(song)
        song.voices.flat_map do |part|
          next [] unless part.instrument

          from_file = (part.from_file&.instruments || []).map { |name| Sounding.new(name: name, envelope: part.envelope) }
          part.events.map do |event|
            Sounding.new(name: event[2] || part.instrument, envelope: event[4] || part.envelope)
          end.push(Sounding.new(name: part.instrument, envelope: part.envelope), *from_file)
        end.uniq
      end

      # Which of the console's voices a part plays on, read off the part itself. One reader, so
      # no backend and no check can decide it differently — that is the same reason this whole
      # module exists.
      #
      # A part names its voice by what it sounds like: an instrument it plays, a waveform, or
      # the hiss. Naming none of those is the square wave, which is what a part was before any
      # of the others existed and is still what most parts are.
      def part_kind(part) = Audio::Music.kind_played({ instrument: part.instrument, wave: part.wave, noise: part.noise })

      # How a note fades or swells, as a part or the note itself SET it (an Audio::NoteFade), or
      # nil when neither did. A note's own comes first. What was set is what the log names, so
      # a song that sets nothing about fading logs what it always did.
      #
      # A note that set nothing is left to its voice: a drum hit rings out as its part's +decay+
      # sets, and a square note holds. Every backend that plays a note works that out itself, from
      # this and the part.
      def said_fade(part, event) = event[Audio::Music::Part::FADE_SLOT] || part.fade

      # Whether a note sounds, and so holds its voice against a sound effect of a lower rank, where
      # one that does not lets the voice go as a rest does: a note with a pitch, at a volume above
      # nought — or one written at nought that a square or noise voice swells up by itself
      # (+fade+, an Audio::NoteFade, going up a step at a time), which is heard from its first
      # step. A recording sounds at its mix's loudness, and the wave voice at a volume it can play.
      # Every backend answers it alike, so they share a voice alike.
      def note_sounds?(kind, frequency, volume, fade)
        return false unless frequency.positive?
        return true if fade&.swells_by_itself? && %i[square noise].include?(kind)
        return false unless volume.positive?
        return mix_loudness(volume).positive? if kind == :recorded

        kind != :wave || Audio::Sound.wave_level(volume) != :mute
      end

      # How a note slides its pitch (an Audio::PitchSlide), as the note or its part set it, or nil
      # when neither did. Only the first square voice slides, and a part elsewhere saying one was
      # refused before it got here.
      def said_slide(part, event) = event[Audio::Music::Part::SLIDE_SLOT] || part.slide

      # How a note wobbles its pitch (an Audio::Vibrato), as the note or its part set it, or nil.
      def said_vibrato(part, event) = event[Audio::Music::Part::VIBRATO_SLOT] || part.vibrato

      # Where a note sits between the speakers (an Audio::Pan), as the note or its part set it, or
      # nil for both whole — which a note that names :center is, in a part that pans.
      def note_pan(part, event) = event[Audio::Music::Part::PAN_SLOT] || part.pan

      # The speaker a note plays from on a voice that only switches between them: :left or :right,
      # or nil for both (Audio::Pan.side_of), a shade taken to the nearest of the three.
      def note_side(part, event) = Audio::Pan.side_of(note_pan(part, event))

      # A square note's shape, or the shapes it steps through (an Audio::Duty), as the note or its
      # part named a Duty, or nil when neither did — a part that names one shape plays it, as it
      # always did, and sets nothing here.
      def said_duty(part, event) = event[Audio::Music::Part::DUTY_SLOT] || part.duties

      # A drum's own noise setting, [divider, halvings], when its note set one, or nil. Only a
      # console told the setting itself reads it: the rate it makes is the note's pitch already.
      def said_noise_clock(event) = event[Audio::Music::Part::NOISE_CLOCK_SLOT]

      # A recorded note's envelope as a sound chip keeps it (an Audio::SNESEnvelope), where the
      # note or its part was given one, or nil. It goes with the envelope that shapes the note: a
      # note that set its own envelope has its own bytes or none, whatever its part was given,
      # and a note that set none has its part's. Nil for a note and a part that set no envelope
      # at all, which is shaped as the recording was declared; the backend holding the
      # declarations knows that one. Only a console whose chip takes the bytes reads this: the
      # nearest ordinary shape is in the envelope's own place already.
      def said_chip_envelope(part, event)
        event[4] ? event[Audio::Music::Part::CHIP_ENVELOPE_SLOT] : part.chip_envelope
      end

      # Whether +event+ carries on the note sounding at a new pitch, rather than striking one.
      def glides?(event) = event[Audio::Music::Part::GLIDE_SLOT] == true

      # The recording a glide reads on, as a build that works a glide's speed out ahead must name it:
      # the one the note before it in +part+ struck, the last that sounds and does not glide (its own
      # instrument, or its part's), which is the note sounding when the glide comes, first time round
      # and every time after (a song coming round puts every part as it was then). The interpreter
      # reads the voice sounding instead (Reference::Mixer#glide_music_note), which is the same. The
      # part's own for a glide with no note struck before it, which then has nothing to carry on.
      #
      # The one place the two can part: a glide on the very frame a song comes round to, after a song
      # whose last note plays another recording than the note before that frame. Coming round, the
      # note sounding is the song's last, and a build's one row for the glide reads the other. Music
      # read off a cartridge comes round where its driver is as it was, the same note sounding, so it
      # never has such a glide.
      def struck_instrument(part, event)
        at = part.events.rindex { |each| each.equal?(event) } || 0
        struck = part.events.first(at).reverse.find { |each| each[1].positive? && !glides?(each) }
        struck&.at(2) || part.instrument
      end

      # Whether a drum hit rattles (the noise voice's short, metallic hiss): its note's own setting
      # where it was given one (Score::Note#metallic), else its part's.
      def said_metallic(part, event)
        own = event[Audio::Music::Part::METALLIC_SLOT]
        own.nil? ? part.metallic : own
      end

      # Whether any note of +part+ was given its own rattle. A console that keeps a part's
      # rattle once, with what the part sounds like, then keeps each note's instead.
      def notes_say_metallic?(part) = part.events.any? { |event| !event[Audio::Music::Part::METALLIC_SLOT].nil? }

      # The waveform a wave note plays: its own when it named one (Score::Note#own_wave), else its
      # part's. +own_wave+ is the note's alone, nil for its part's.
      def said_wave(part, event) = own_wave(event) || part.wave
      def own_wave(event) = event[Audio::Music::Part::WAVE_SLOT]

      # Every waveform +part+ plays, its own first and then each its notes name, once each.
      def waves_of(part) = [part.wave, *part.events.filter_map { |event| own_wave(event) }].compact.uniq

      # Whether any part of +songs+ has a note that names a waveform of its own: a console that puts a
      # tune's waveform in once as it starts then puts each note's in as it starts.
      def notes_name_waves?(songs) = songs.any? { |song| song.voices.any? { |part| part.events.any? { |event| own_wave(event) } } }

      # A note setting its voice, as every backend's log says it: [:voice, channel, who, frequency,
      # volume], then the note's fade, its slide and its wobble when it set them (#said_fade,
      # #said_slide, #said_vibrato), its side when it is one speaker (#note_side), and its shape
      # when it set one (#said_duty), with a nil before one set after it. A rest sets none of
      # them: nothing sounds to change.
      def voice_entry(channel, who, frequency, volume, fade: nil, slide: nil, vibrato: nil, side: nil, duty: nil)
        said = frequency.positive? ? Audio::Music.without_trailing_nils([fade, slide, vibrato, side, duty]) : []
        [:voice, channel, who, frequency, volume, *said]
      end

      # The wobble of a note a voice holds, a frame at a time — the same steps on every backend
      # (Audio::Vibrato says what they mean). +wait+ is the frames still to go before it starts,
      # +left+ the frames the swing it is in has still to hold, +rising+ whether that swing is the
      # one above, and +steps+ how far from the note's own pitch it has the voice now.
      Wobble = Data.define(:vibrato, :wait, :left, :rising, :steps) do
        # A voice given a note that wobbles: nothing moved yet. A vibrato that carries
        # (Audio::Vibrato#carries) takes up the swing +before+ left off — the voice's last wobble,
        # or nil for none — and starts only its wait over.
        def self.starting(vibrato, before = nil)
          return new(vibrato: vibrato, wait: vibrato.after, left: 0, rising: false, steps: 0) unless vibrato.carries && before

          new(vibrato: vibrato, wait: vibrato.after, left: before.left, rising: before.rising, steps: 0)
        end

        # The wobble a frame on, stepped once at the end of every frame the player plays, the frame
        # its note began included. It waits, and then, as each swing runs out, turns to the other
        # side of the note's pitch, above first, and holds there for the vibrato's speed in frames.
        def stepped
          return with(wait: wait - 1) if wait.positive?

          turned = left.zero? ? with(rising: !rising, left: vibrato.speed, steps: rising ? -vibrato.below : vibrato.above) : self
          turned.with(left: turned.left - 1)
        end
      end

      # A swelling note held under the music volume, counted a frame at a time — the same count on
      # every backend.
      #
      # A square voice counts a swelling note's loudness up by itself, a step every +step+ 64ths of
      # a second, and stops only at full (15): it knows nothing of the music volume. So while the
      # game moves the music volume, the player counts along with it, and when the note has
      # reached the loudest the music volume lets a note be (#ceiling), strikes it again there,
      # holding. If the music comes back up, it strikes it again where it was held, swelling on;
      # if it goes down further, it strikes it lower. +volume+ is how loud the voice has the note
      # now, +counted+ the 256ths of a 64th counted toward its next step, and +swelling+ whether the
      # voice is still counting it up.
      Swell = Data.define(:step, :volume, :counted, :swelling) do
        # A note struck swelling, at +volume+: nothing counted yet.
        def self.starting(step, volume) = new(step: step, volume: volume, counted: 0, swelling: true)

        # The swell a frame on: a frame is a little longer than a 64th of a second
        # (COUNTED_A_FRAME), so a step of 1 can climb twice in a frame, now and then.
        def stepped
          return self unless swelling && volume < LOUDEST

          counted = self.counted + COUNTED_A_FRAME
          volume = self.volume
          while counted >= step * 256 && volume < LOUDEST
            counted -= step * 256
            volume += 1
          end
          with(volume: volume, counted: counted)
        end

        # What the player strikes under +ceiling+, and the swell after: nil for nothing, :hold
        # for the note struck at the ceiling holding, :swell for it struck where it is, swelling
        # on. At full there is nothing to hold: the voice stops there by itself.
        def held_under(ceiling)
          if swelling && volume >= ceiling && ceiling < LOUDEST
            [with(volume: ceiling, counted: 0, swelling: false), :hold]
          elsif !swelling && volume > ceiling
            [with(volume: ceiling), :hold]
          elsif !swelling && volume < ceiling
            [with(counted: 0, swelling: true), :swell]
          else
            [self, nil]
          end
        end
      end

      # How loud a console voice can be.
      LOUDEST = 15

      # The 256ths of a 64th of a second a frame lasts (Swell#stepped), rounded down. Every console
      # VBlank plays on today shows a frame for the same time; one whose frame is another length
      # needs its own number here.
      COUNTED_A_FRAME = 274

      # The loudest a note can be at music volume +level+.
      def ceiling(level) = scaled_volume(LOUDEST, level)

      # Which kinds of voice have a note that swells by itself in a song the program plays — a song,
      # not a sound effect, which keeps its own volume? Only those have a swell for a player to hold
      # under the music volume (Swell). A drum hit is held the same way, struck again on the noise
      # voice, which starts its hiss over: that is heard as one more hit under the swell, and the
      # note is held down, which is what the music volume is for.
      def swelling_voice_kinds(program)
        effect_names = effects(program)
        songs = played_songs(program).reject { |song| effect_names.include?(song.name) }
        swelling = songs.flat_map(&:voices).select do |part|
          part.events.any? { |event| event[1].positive? && said_fade(part, event)&.swells_by_itself? }
        end
        swelling.map { |part| part_kind(part) }.uniq & %i[square noise]
      end

      # Does the voice change this note itself — a square note that set a fade or a swell with a
      # step to count, or a slide? Such a note is not held for the music volume: the volume reaches
      # a held note by striking it again, which would start its counting over, so a plucked note
      # would never die away while the music fades, and a swoop would start again from the top. It
      # is left to change as a drum hit is, and a new music volume reaches the part's next note.
      def changes_by_itself?(part, event)
        said_fade(part, event)&.step&.positive? || Audio::PitchSlide.moves?(said_slide(part, event))
      end

      # How many of a song's parts play on each of the console's voices.
      def parts_on(song, kind)
        song.voices.count { |part| part_kind(part) == kind }
      end

      # How many of a song's parts play a recording rather than one of the console's own voices.
      def recorded_parts(song) = parts_on(song, :recorded)

      # Whether +program+ has a song or sound effect with a recorded note off the middle of the
      # speakers, which a console with a volume for each side of a voice then works out (Audio::Pan).
      def recorded_pans?(program)
        program.walk.any? do |node|
          node.kind == :song && node.voices.any? do |part|
            part_kind(part) == :recorded && part.events.any? { |event| !Audio::Pan.centered?(note_pan(part, event)) }
          end
        end
      end

      # The most recorded parts any one played tune has — how many parts the player has to be
      # ready to find a voice for at once, since one tune plays at a time.
      def most_recorded_parts(program)
        played_songs(program).map { |song| recorded_parts(song) }.max || 0
      end

      # The frame a song goes back to at its end: 0, unless it has a loop point.
      def loop_frame(song) = song.loop_frame || 0

      # Does the song play once, and end rather than come round? One that does lasts exactly its
      # length, and a song node that is marked so and names a loop frame as well still ends. On the
      # frame after its last, its parts go quiet the way they do when the program stops the
      # music, and from then on no tune is playing — though the program may go on naming this
      # one, since naming the tune already named changes nothing. It is heard again when the
      # program stops the music and names it, or names another tune first.
      #
      # Every backend takes those steps in that order, because the frame a song goes quiet on
      # is one a player can hear.
      def plays_once?(song) = song.plays_once ? true : false

      # Who sounds on a voice two players want at once — the song and a sound effect, or two
      # effects — as one number each, so a single comparison settles it on every backend.
      #
      # The higher priority takes the voice. A tie goes to a sound effect over the song, and
      # between two effects to the one declared first: the priority sits in the top half of the
      # number and the order in the bottom half, the song's bottom half 0 and the first effect's
      # the largest. A note takes a voice whose holder's rank is no higher than its own, so a
      # player's next note always takes back the voice its last one held — and a voice nobody
      # holds is rank 0, which every note takes.
      #
      # The bottom half tells the two kinds of holder apart as well: it is 0 for the song and
      # never 0 for an effect, which is how a song that stops knows to leave an effect's voice
      # alone.
      RANK_SHIFT = 16
      ORDER_MASK = (1 << RANK_SHIFT) - 1

      def song_rank(song) = (song.priority || 0) << RANK_SHIFT

      # +order+ counts the program's sound effects from 0, in the order they were declared.
      def effect_rank(song, order) = song_rank(song) | (ORDER_MASK - order)

      # Every rank a game's songs and sound effects can have, the lowest first, nobody's (0) the
      # first of all — given the songs the game plays and its sound effects' songs in the order they
      # were declared. A cartridge that keeps each rank as its place in this list rather than the
      # number itself keeps a byte where it would keep four, and places compare as ranks do.
      def ranks_in_order(songs, effect_songs)
        ([0] + songs.map { |song| song_rank(song) } +
         effect_songs.each_with_index.map { |song, order| effect_rank(song, order) }).uniq.sort
      end

      # The priority a rank carries, without the order under it — what decides between two sound
      # effects of one group (a song node's +group+), which play one at a time. Asked for while
      # another of its group is sounding or already asked for, an effect of at least that one's
      # priority stops it and starts in its place, a tie going to the one asked for; one of lower
      # priority is not played at all. An effect with no group plays alongside any other.
      def priority_of(rank) = rank >> RANK_SHIFT

      # Every sound effect the program declares, in order: the songs of each effect list.
      def effects(program)
        program.walk.select { |node| node.kind == :sound_effect_list }.flat_map(&:effects)
      end

      # ### The timer the sound effects tick on
      #
      # A game whose sound effects say `on_timer:` (Audio::Score) counts their ticks on a timer of
      # their rate, running from power-on, as a cartridge's own sound engine counts them on a timer
      # of its sound chip's. Every player keeps the timer the same way, once a frame from the first,
      # as the frame's sound effects are about to play: it adds this step to a count of 16 bits, and
      # the frame has a tick each time the count goes past the top and comes round. An effect asked
      # for starts at once, on the frame the player takes the ask up, as a sound driver strikes an
      # effect's first note the moment it is told, whether or not the frame has a tick; on a frame
      # with a tick every effect sounding then plays one tick, as it plays a frame in a game with no
      # timer, one that has just started included (Reference::Player#play_effects_first_pass).
      #
      # The step is the part of a tick a frame is, in 65536ths, rounded down: the console's own
      # frame (Console::Description#frame_seconds), not a round sixty a second, since the timer
      # keeps real time and the console's frames are a little longer or shorter. Worked out from
      # whole numbers, so the interpreter and every build agree to the frame. Nil for a game whose
      # effects are not on a timer.
      #
      # ### Several ticks in one frame
      #
      # A timer faster than the frames (60, 120 and 240 ticks a second are common rates for a sound
      # driver) has a step of a whole count or more, and a frame then holds one tick for each time
      # the count comes round. Every player plays such a frame the same way, in this order:
      #
      # 1. The first tick around the song's frame, as a frame of one tick plays: the effects that
      #    outrank the tune, the song's frame, then the rest. What was asked for starts here.
      # 2. Each later tick after that, the effects that outrank the tune first, then the rest.
      #
      # A part whose notes fall on two ticks of one frame plays both, in order, so its voice is left
      # sounding the second, and both are logged. A console that strikes a note inside the frame at
      # its tick's own time (the Super Nintendo's sound unit, the PlayStation's root counter) logs
      # and claims voices in this order too; only the moment the chip is told differs. A frame
      # holds MOST_TICKS_A_FRAME at most (Guardrails::Checks::EffectTimerTooFast).
      #
      # ### The game's own sound against a listed strike
      #
      # Every player plays the frame's ticks before the game's pass that follows, so the game's own
      # sound on a voice (`beep`, `noise`, `wave`, `stop_wave`) comes after every note the frame's
      # ticks wrote there, and the voice keeps the game's. A console that strikes inside the frame
      # keeps that: the game's sound is written to the chip at once, as the game plays it, and every
      # write to that voice still waiting on the strike list is dropped, the waveform the wave voice
      # was to load with them, and the voice's speaker switches taken out of a waiting speaker write.
      # Never folded into the waiting write, which would hold the game's sound back to the strike's
      # line, with the effect's note sounding until then where the interpreter has the game's.
      #
      # A key-off and a key-on of one voice in one frame (an effect letting a voice go and a tune
      # taking it back) stay two writes in that order, never merged into one: merged, the voice is
      # never let go and the tune's note starts without its attack.
      #
      # ### On the driver's own interrupt
      #
      # An effect whose Score names `interrupts_per_second:` counts on two clocks, as a driver that adds
      # its tempo up on an interrupt of its own does. The clock above is then the interrupt's: a frame
      # adds this step for it, and holds an interrupt each time the count comes round. On each interrupt
      # the tempo's count adds #effect_tempo_step, and the interrupt holds a tick where that comes round,
      # so a tick only ever falls on an interrupt. An effect asked for starts on the frame's first
      # interrupt (at the frame's start where the frame holds none), and moves on from a tick on a later
      # interrupt: a tick on the interrupt it started on is not its (Reference::Player#advance). The
      # tempo is counted on the interrupt, which comes more often than the ticks, so an interrupt holds one
      # tick at most and the step is under a whole tick.
      #
      # The interrupt is read against the console's own sound clock: a driver's timer is a divider of
      # the sound unit's clock, and where that runs off the rate its documentation names
      # (Console::Description#sound_clock_ratio), its interrupts come that much
      # more or less often. What a tick is worth on each, the tempo's step, is the driver's own, unmoved.
      def effect_clock_step(program, console)
        interrupts = effect_interrupt_rate(program)
        return (interrupts * driver_seconds_a_frame(console) * CLOCK_MODULUS).floor if interrupts

        rate = effect_timer_rate(program) or return nil
        (rate * console.frame_seconds * CLOCK_MODULUS).floor
      end

      # How long one of +console+'s frames lasts on the clock a sound driver's own timer keeps, in the
      # seconds that clock's documentation names: the frame's real length, times how much faster the
      # sound unit runs than named (Console::Description#sound_clock_ratio). On the Super Nintendo the
      # timers divide the sound unit's clock, which runs near 32040 samples a second where its output
      # is named for 32000 (fullsnes, "SNES APU"), so a frame holds that much more of the driver's time.
      def driver_seconds_a_frame(console) = console.frame_seconds * console.sound_clock_ratio

      # ### A song on the driver's own interrupt
      #
      # A cartridge's sound driver runs its songs and its effects on its one timer: each interrupt adds
      # the song's tempo to the count, and a row of the song plays where the count comes round, just as
      # an effect's note does (#tune_tempo_step). So where a game's driver names its interrupt, every
      # song a Score gives keeps time on that interrupt, not only the ones the effects count their tempo
      # at: its notes are laid out in the console's frames, as many a second of the driver's clock as
      # that second really holds (Audio::Score#to_song). Its ticks then fall where the count's do, and
      # the effects asked for over it keep in step with it over a long run.
      #
      # The frames a song is laid out in are worked out once, as the game is built, and the interrupts
      # fall at a different place in each frame, so a note can be a frame either side of the count's
      # tick; what the two cannot do is drift apart. A game whose driver names no interrupt keeps the
      # round Audio::Score::FRAME_RATE, as a `song` block always does.
      def driver_song_frame_rate(console) = 1 / driver_seconds_a_frame(console)

      # What the tempo's count adds on each interrupt of the driver's own (#effect_clock_step), in 65536ths
      # of a tick, rounded down; nil for effects with no interrupt named, whose clock is the tick's own.
      def effect_tempo_step(program)
        interrupts = effect_interrupt_rate(program) or return nil
        (effect_timer_rate(program) / interrupts * CLOCK_MODULUS).floor
      end

      # Do the game's sound effects cut their own notes (Audio::Score's +cuts_own_notes+): each recorded
      # note of a part on the voice of the part's note before it? All of them do, or none.
      def effects_cut_notes?(program) = program.walk.any? { |node| node.kind == :song && node.cuts_own_notes }

      # Where a song's start sets the tempo count on a driver's interrupt, in 65536ths of a tick, or nil for
      # nowhere (Audio::Score's +tick_count_at_song_start+). A song starts where the player takes up a tune,
      # before it counts that frame's ticks (Reference::Player#switch_to_wanted_song). From there the count
      # adds that same share each interrupt until it comes round, and then the tempo again.
      def effect_count_at_song_start(program)
        share = program.walk.find { |node| node.kind == :song && node.timer_rate && node.tick_count_at_song_start }
        (share.tick_count_at_song_start * CLOCK_MODULUS).floor if share
      end

      # Do the effects count their tempo at the tempo of the song playing (Audio::Score's +on_tune_tempo+)?
      def effects_on_tune_tempo?(program) = program.walk.any? { |node| node.kind == :song && node.on_tune_tempo }

      # What a driver's tempo count adds on each interrupt while +song+ plays, with the effects on its tempo
      # (#effects_on_tune_tempo?): the song's ticks a second over the interrupt's, in 65536ths, at most a
      # whole tick less one; nought for a song with no one tempo (Audio::Score#tick_rate).
      def tune_tempo_step(program, song)
        return 0 unless song.tick_rate

        [(song.tick_rate / effect_interrupt_rate(program) * CLOCK_MODULUS).floor, CLOCK_MODULUS - 1].min
      end

      # ...for every song the program declares, in the order declared (#declared_songs, whose place one up
      # is the song's number on the consoles), or nil where the effects keep a tempo of their own.
      def tune_tempo_steps(program)
        effects_on_tune_tempo?(program) ? declared_songs(program).map { |song| tune_tempo_step(program, song) } : nil
      end

      # ...the same by each song's name, or nil, for a lowering that numbers its tunes its own way.
      def tune_tempo_steps_by_name(program)
        steps = tune_tempo_steps(program) or return nil
        declared_songs(program).map(&:name).zip(steps).to_h
      end

      # Does the effects' tempo count ever add something other than one fixed step: the share a song's start
      # sets until the count comes round (#effect_count_at_song_start), or the tempo of the song playing
      # (#effects_on_tune_tempo?)? Every lowering then keeps the share as it counts.
      def effect_tempo_varies?(program) = !effect_count_at_song_start(program).nil? || effects_on_tune_tempo?(program)

      # Does the driver key an effect only on a wake whose count comes round, a tick, rather than on the
      # first wake after it is asked for (Audio::SoundDriver's +effects_start+ `:on_next_tick`)?
      def effects_start_on_tick?(program) = program.walk.any? { |node| node.kind == :song && node.starts_on_tick }

      # ...and skip its tick while the music is at volume 0 (Audio::SoundDriver's +silent_music_stops_ticks+)?
      def silent_music_stops_ticks?(program) = program.walk.any? { |node| node.kind == :song && node.silent_music_stops_ticks }

      # Does any request say the screen row it is sent at (`sent_after_rows:`)?
      def requests_at_rows?(program) = program.walk.any? { |node| ROW_REQUESTS.include?(node.kind) && node.sent_after_rows }

      ROW_REQUESTS = %i[play_sound_effect play_from_list play_song].freeze

      # How far into a frame a request sent +rows+ screen rows after the vertical blank starts is, counted
      # in the frame's wakes of the driver, in 65536ths: the frame starts where the blank does, and the
      # wakes come +clock_step+ 65536ths a frame (#effect_clock_step). A frame's first wake is the one its
      # count, starting at its share left from the frame before, reaches first; the request comes before
      # the first wake whose place in the frame is past this. Rounded down, as the step is.
      def row_share(rows, clock_step, console)
        (Rational(rows) * console.cycles_a_line / console.cycles_a_frame * clock_step).floor
      end

      # ...for a request of +program+ at +rows+, on its console's driver wakes: what a lowering hands its
      # runtime, worked out as the build is made.
      def request_row_share(program, rows)
        console = program.described_console
        row_share(rows, effect_clock_step(program, console) || 0, console)
      end

      # The sound driver's habits as bits, for a runtime that reads them from one number of its effects
      # table: the count at the tune's tempo, an effect started only on a tick, silent music stopping the ticks.
      HABIT_TUNE_TEMPO = 1
      HABIT_STARTS_ON_TICK = 2
      HABIT_SILENT_STOPS_TICKS = 4

      # ...those +program+ names.
      def driver_habit_bits(program)
        (effects_on_tune_tempo?(program) ? HABIT_TUNE_TEMPO : 0) | (effects_start_on_tick?(program) ? HABIT_STARTS_ON_TICK : 0) |
          (silent_music_stops_ticks?(program) ? HABIT_SILENT_STOPS_TICKS : 0)
      end

      # How many times a second the driver's interrupt comes, for effects that name one, or nil.
      def effect_interrupt_rate(program)
        program.walk.find { |node| node.kind == :song && node.interrupt_rate }&.interrupt_rate
      end

      # A rate of the sound effects' timer as the messages about it give it: "50 times a second", or
      # with three places of a fraction where it has one.
      def timer_rate_words(rate) = "#{rate.denominator == 1 ? rate.to_i : rate.to_f.round(3)} times a second"

      # How many times a second the sound effects' timer ticks, or nil for none: the one rate every
      # effect of the game has (Builder#sound_effects holds them to one).
      def effect_timer_rate(program)
        program.walk.find { |node| node.kind == :song && node.timer_rate }&.timer_rate
      end

      # The count the sound effects' timer keeps comes round at this: 16 bits.
      CLOCK_MODULUS = 1 << 16

      # The most ticks of the sound effects' timer one frame can hold: a little under 480 a second
      # at sixty frames. Each tick's notes are a pass over the effects, and on a console that
      # strikes them inside the frame, a short list its sound unit keeps until their time comes.
      MOST_TICKS_A_FRAME = 8

      # How many ticks the frames hold at most with +step+ (#effect_clock_step).
      def most_ticks_a_frame(step) = (step + CLOCK_MODULUS - 1) / CLOCK_MODULUS

      # ...and their song nodes, with every song the program plays: all it can sound.
      def playable_songs(program)
        names = effects(program)
        played_songs(program) + program.walk.select { |node| node.kind == :song && names.include?(node.name) }
      end

      # The order a frame plays the sound effects in: highest rank first, as [name, rank] — given
      # the effects' song nodes in the order they were declared. Played in this order, with the
      # song's parts at their own rank's place among them, whoever writes a voice first on a
      # frame is whoever keeps it.
      def effects_by_rank(songs)
        songs.each_with_index.map { |song, order| [song.name, effect_rank(song, order)] }
             .sort_by { |_, rank| -rank }
      end

      # Each part's notes the first time round, and every time after.
      #
      # A song that loops from a point plays what comes before it once: at its end the song
      # goes back to the loop frame and every part carries on from there. What makes that more
      # than moving a place in each list is what a part is doing at the loop frame. The first
      # time round it gets there from the notes before; every time after, it gets there from
      # the end of the song, still sounding whatever it ended on. So each part is put into the
      # state the loop frame wants:
      #
      #   * a note that starts right there already does it;
      #   * a part silent there, and silent at the end, needs nothing;
      #   * a part silent there but still sounding at the end gets a rest there — which, the
      #     first time round, silences a part that is already silent, and so changes nothing;
      #   * a part holding a note across the loop frame sounds that note again there, every
      #     time after the first. Not the first time: the note is already sounding then, and
      #     striking it again would be heard. So those parts alone get a list of their own for
      #     the later passes, starting with the held note. Unless the song ends on that same
      #     note — then it is still sounding when the song comes round, and simply carries on.
      #
      # A song that loops from its start is the same rule with nothing before the loop frame, so
      # all it can ever need is the rest — which is also what stops a part that comes in late
      # from ringing on into the first frames of the song each time round.
      #
      # +first+ is the part's events the first time; +again+ is every time after, and is the
      # tail of +first+ unless the part holds a note across the loop frame.
      Pass = Data.define(:first, :again)

      # A song that ends has no later pass, and nothing to be put right for one.
      def loop_passes(song)
        return song.voices.map { |part| Pass.new(part.events, []) } if plays_once?(song)

        from = loop_frame(song)
        if from.positive? && from >= song.total_frames
          raise ArgumentError, "song #{song.name.inspect} loops from frame #{from}, and is #{song.total_frames} frames long"
        end

        song.voices.map { |part| part_loop_pass(part.events, from) }
      end

      def part_loop_pass(events, from)
        split = events.index { |event| event.first >= from } || events.size
        before = events.first(split)
        after = events.drop(split)
        return Pass.new(events, after) if after.first&.first == from

        held = before.last
        ending = events.last
        unless sounding?(held)
          return Pass.new(events, after) unless sounding?(ending)

          first = before + [[from, 0]] + after
          return Pass.new(first, first.drop(split))
        end
        return Pass.new(events, after) if ending.drop(1) == held.drop(1)

        Pass.new(events, [[from, *held.drop(1)]] + after)
      end

      # Does anything sound once the song has come round? A part does if a note in its later
      # passes does — which counts a note held across the loop frame and sounded again there —
      # or if the song ends on a note, which then carries on into the repeat.
      # A part whose notes are known only once the program reads its file may sound there.
      def repeat_sounds?(song)
        song.voices.zip(loop_passes(song)).any? do |part, pass|
          part.from_file || sounding?(part.events.last) || pass.again.any? { |event| sounding?(event) }
        end
      end

      def sounding?(event) = !event.nil? && event[1].positive?
    end
  end
end
