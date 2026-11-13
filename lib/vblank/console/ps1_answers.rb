# frozen_string_literal: true

module VBlank
  module Console
    # WHAT EVERY VERB DOES ON A PLAYSTATION (Console::Answers says what an answer is).
    #
    # The PlayStation is a 32-bit console of 1994 with a MIPS R3000A at its heart and a graphics chip
    # that draws flat, shaded and textured triangles, rectangles and lines into a megabyte of video RAM
    # of its own. It has no tiles and no sprites in the older consoles' sense: everything on the screen
    # is drawn by the graphics chip, every frame, from a list of commands. So a sprite is a textured
    # rectangle, a background is a picture kept in video RAM and drawn as one, and there is no limit of
    # sprites on a row. Its colours are 15 bits, as the Advance's are, through lists of 16 or 256
    # colours kept in video RAM. It has no clock chip, and its pad has more buttons than the Advance's.
    #
    # A GAME NAMES WHICH CONSOLES IT IS FOR (`VBlank.game "PONG", consoles: %i[gba ps1]`), and is laid out
    # from `screen_width` and `screen_height` rather than from 240 and 160, so the same game fills each
    # screen.
    #
    # An answer here is what the console's hardware does. What the PlayStation build does not make yet is
    # the lowering's own list (Backends::PS1::Lowering::NOT_LOWERED_YET), which the page shows under its
    # own heading and the build refuses by name.
    module PS1Answers
      extend Answers

      PAGE = ".claude/dsl/playstation.md"

      PLAIN = "the same as on the Advance."

      ANSWERS = Ractor.make_shareable({
        # --- building, the screen and settings ---
        screen: works("`screen :bitmap` and `screen :tiled` work: the graphics chip draws both into video RAM. " \
                      "The game's screen is the PlayStation's whole picture, 320 × 240, so a game laid out from " \
                      "`screen_width` and `screen_height` fills it, and a painted picture has a colour of fifteen " \
                      "bits in each pixel, the same colours as on the Advance. " \
                      "`tear_free: true` keeps two pictures, one drawn while the other shows. `screen :rotozoom` " \
                      "works too: the chip draws the turned background as a textured shape. `pixel_size: 2` " \
                      "is refused: the build does not show a painted screen bigger yet. `shown_rows:` is " \
                      "refused: a PlayStation can write its video memory at any time, so rows that do not " \
                      "show give it no more time."),
        setting: works,
        built_for_computer?: works("false on a PlayStation."),
        built_for?: works("true when asked about :ps1."),
        screen_width: works("320 on a PlayStation."),
        screen_height: works("240 on a PlayStation."),
        border: works("it does nothing on a PlayStation, which shows the game's screen whole."),
        wait_vblank: works("in a game loop, the sprites and scroll of a pass show on the frame after the wait. " \
                           "If a game writes the wait in a scene or an `if`, they show a frame later than that."),
        halt: works,
        debug_halt: works("the game stops there, as `halt` does; the program is not cut short."),
        game_loop: works,
        once_a_frame: works,
        frames_since_power_on: works,
        each_pass: works,
        every: works,
        after: works,
        repeat: works,
        timer: works("a timer ticks by the frame, as the interpreter counts it."),

        # --- drawing on a painted screen ---
        pixel: works,
        fill_rect: works,
        dma_fill_rect: works,
        draw_rect_at: works,
        draw_column_at: works,
        place: works("a place is data in the program."),
        viewer: works("a viewer is variables."),
        change_picture: works("every picture the place lists is in video memory from the start, so a change " \
                              "copies nothing."),
        shading: works("a shading is data in the program."),
        screen_spot: works("the processor turns and projects the point, as the drawing of a place does."),
        draw_place: works("the processor turns and projects every corner, as the other consoles do. The graphics chip " \
                          "fills each face, by its own rules. Thus some pixels of a face's picture are one pixel or " \
                          "one picture pixel away from where the other consoles put them. In perspective, the " \
                          "processor cuts a face into rectangles, and the picture is exact at the corners of each " \
                          "rectangle. The rectangles are small where the face is near and at a slant. They are " \
                          "narrow in the direction where the distance changes. Thus the picture is approximately " \
                          "four pixels or less from its exact place (two pixels for `perspective: :every_pixel`), " \
                          "and the picture of a near wall stays on the wall as the view turns. A face that is far " \
                          "away or seen straight on is cut into few rectangles or none. The graphics chip lights a " \
                          "face, as the console's own games did: it makes each picture pixel darker by the light, " \
                          "which changes smoothly across the face. If the shading makes each colour darker evenly, " \
                          "a pixel is one level or less from the shading's colour. If the shading changes colours " \
                          "in another way, the pixel is the picture's colour made darker."),
        clear_screen: works,
        inside: works,
        grid: works,
        camera: works,
        keep_showing: works,

        # --- fades, tints and screen effects ---
        fade: works("`fade` and `tint` change the colours the console shows. On a screen drawn from tiles every " \
                    "list of colours the graphics chip reads is worked out again, once, on a pass that changes them. " \
                    "A painted screen that fades is drawn with a number for each colour, 128 colours at most. At the " \
                    "end of each pass, the graphics chip copies it onto the screen through a list of those colours. " \
                    "When the fade changes, the game changes that list. How the chip fades part of the screen (`inside:`, " \
                    "`outside:`, `under:`) is decided when that is made: until then the build refuses it and says so."),
        tint: works,
        fade_in: works,
        fade_out: works,
        flash_screen: works,
        fade_level: works,
        shake_screen: works,
        pixelate: works("the build does not make `pixelate` yet. Until it does, the build refuses a game that " \
                        "pixelates, and names `pixelate`."),
        pixelate_in: works("see `pixelate`."),
        pixelate_out: works("see `pixelate`."),
        pixelate_size: works,
        spotlight: works("how the graphics chip darkens everything outside a circle is decided when the light is " \
                         "made: until then the build refuses a light and says so."),
        iris_in: works("the iris is the game's light closing (see `spotlight`)."),
        iris_out: works("see `iris_in`."),
        iris_shut?: works("see `iris_in`."),
        pulse: works("the graphics chip draws the sprite bigger or smaller as a textured shape."),
        camera_follows: works,

        # --- pictures and sprites ---
        image: works("a picture is kept in video RAM. A picture of 16 colours or fewer takes 4 bits a pixel, and one of " \
                     "256 or fewer takes 8, each pixel a number into a list of its colours. Pictures share a list where " \
                     "their colours fit in one. A picture of more colours takes 16 bits a pixel. A game whose pictures " \
                     "do not fit in video RAM beside the screen is refused when it is built."),
        color: works("a colour has fifteen bits, as on the Advance."),
        rgb: works("see `color`."),
        rgb8: works("see `color`."),
        colors: works("a list of colours holds 256 places on a PlayStation, the first see-through."),
        recolor: works("on a screen drawn from tiles, the list's colours are written into the lists of colours the " \
                       "graphics chip reads, so everything drawn with it changes on the same pass. On a painted " \
                       "screen, a list changes the sprites that draw with it. The build makes sprites over a painted " \
                       "screen (`over_picture: true`) drawn with another list. It does not make a list that " \
                       "changes as the game runs there yet: it refuses it and says so."),
        color_walk: works,
        colors_in_use: works,
        colors_name_of: works,
        mirror: works,
        upside_down: works,
        blit: works,
        sprite: works("a sprite is a picture the graphics chip draws each frame, any size up to 256 × 256. There is " \
                      "no limit of sprites on a row of the screen. A sprite that turns or resizes is drawn as a " \
                      "textured shape. A sprite whose poses are drawn from different lists of colors shows each " \
                      "pose in the colors of its own list. On a painted screen, a sprite with `over_picture: true` is " \
                      "drawn over a copy of the picture as it goes to the screen, so the picture stays as the game " \
                      "painted it. The build does not make a sprite painted into the picture yet: it refuses it and " \
                      "says so."),
        draw_in_order: works,
        hide_sprites: works,
        picture_groups: works,
        pool: works,
        box: works,

        # --- backgrounds and layers ---
        tiles: works,
        background: works("a background is a picture kept in video RAM, drawn by the graphics chip at its scroll. " \
                          "Each pixel is a number into a list of the background's colours, 4 bits a pixel for 15 " \
                          "colours or fewer and 8 for 255 or fewer, so `draw_with` and a fade change one list. " \
                          "A background of more colours takes 16 bits a pixel, and its colours cannot change. " \
                          "`show_only_inside` holds it to the chip's drawing area, and a background that turns or " \
                          "resizes is drawn as a textured shape. On a painted screen, a background is painted into the " \
                          "picture where it is put up. The build does not make one there that moves or changes yet. A " \
                          "game can show a painted screen and one drawn from tiles at different times; the build does " \
                          "not make a fade or a tint in such a game yet. It refuses each of these and says so."),
        status_bar: works,
        canvas: works,
        tile_pictures: works,
        sprite_tiles: works,
        layers: works,
        layer: works("see `layers`."),

        # --- text ---
        draw_text: works,
        draw_number: works("see `draw_text`."),
        font: works("a font of the game's own pictures (`pictures:` or `strip:`) draws each character as its " \
                    "picture: a `blit` on a painted screen, a sprite on a tiled one."),
        text_width: works,
        text_height: works,
        menu: works,

        # --- numbers and logic ---
        var: works("a variable is the same 32-bit whole number as on the Advance."),
        save_var: works("kept on the memory card in the first slot."),
        save_data: works("kept on the memory card in the first slot."),
        part: works, start_over: works,
        clock: refused("a PlayStation has no clock chip. Ask the player for the time on a screen of the game's own, " \
                       "if the game needs it."),
        saves_keep_everything: works,
        set: works, add: works, add_var: works,
        sub: works, sub_var: works, copy: works,
        negate: works, negate!: works, flip: works, flip!: works, abs: works, abs!: works,
        negate_abs: works, negate_abs!: works, clamp: works, clamp!: works,
        approach: works, approach!: works,
        list: works,
        func: works("`fast:` means nothing on a PlayStation, which runs all of its code alike."),
        call: works,
        scene: works("see `func` for `fast:`."),
        case_var: works,
        uses: works("a pack's verbs are verbs of the game's own, and each one has its answer here."),
        data_pack: works("the program holds what each slot holds, as if the game had written it."),
        shell_screen: works("the program holds nothing of it. Only a build as a shell shows a first screen."),
        dump_func: refused("it lists the ARM a routine was made into, and a PlayStation has no ARM processor to list it for."),
        entry: refused("`entry` is raw ARM for the Advance's processor, which a PlayStation does not have."),

        # --- input ---
        held: works("a game names the pad's buttons by the shared names: `:a` is Cross, `:b` Circle, `:x` Triangle, " \
                    "`:y` Square, `:l` L1 and `:r` R1, with `:select`, `:start` and the D-pad. A PlayStation has two " \
                    "ports for pads. The build reads the first alone for now, so `player: 2` and `players:` more " \
                    "than 1 are not made yet."),
        pressed: works("see `held`."),
        most_players: works,
        drawing_for_local_player: works("the player is always 1: a console is played by one person."),
        mark: works,
        players_connected: works("1 while the build reads the first pad alone."),
        rumble: works("nothing is felt. The build reads a digital pad, which has no motor, so the game plays the " \
                      "same without it."),
        computer_keys: works(Answers::COMPUTER_ONLY), computer_gamepad: works(Answers::COMPUTER_ONLY),

        # --- randomness ---
        seed: works, randomize: works, roll: works, rand: works, chance: works, random_numbers: works,

        # --- sound and music ---
        enable_sound: works(Answers::MAIN_VOLUME_NOT_MADE_YET),
        define_sound: works("the sound chip plays a square as a short recording of one wave, on a voice of its own. " \
                            "A fade moves the voice's loudness a step at a time, at the same pace as on the Advance."),
        beep: works("see `define_sound`."),
        noise: works("the sound chip plays the Advance's noise as a recording, at the pitch the game names. " \
                     "A metallic noise is a recording of the Advance's rattle."),
        wave: works("the waveform is played as a short recording of seven waves. Its loudness is one of the same " \
                    "five steps as on the Advance."),
        stop_wave: works,
        song: works("#{Answers::PAN_LEAD} #{Answers::NEAREST_SIDE} #{Answers::RECORDINGS_WHERE_PANNED}"),
        play_song: works,
        stop_music: works,
        hold_music: works,
        release_music: works,
        music_volume: works,
        fade_music_in: works,
        fade_music_out: works,
        songs: works("see `song`. #{Answers::NOTE_VOICES_NOT_UNDER_VOLUME}"),
        sound_effects: works("see `song`."),
        sample: works("the sound chip plays recordings itself, each on a voice of its own with its own loudness and " \
                      "shape, 16 at once."),
        instrument: works("see `sample`.")
      })

      # The verbs whose refused part is the build's limit and not the console's: a fade of part of the screen
      # asks a console that blends (Console::Questions), and how the PlayStation's graphics chip does it is
      # decided when it is made. Until then the lowering refuses it as not made yet
      # (Backends::PS1::Lowering::NOT_LOWERED_YET), never in the words of hardware the console lacks.
      UNMADE_VERBS = %i[fade].freeze

      # Answers#refusals, less the lines whose verb is one of UNMADE_VERBS.
      def self.refusals(nodes, console)
        super.reject { |refusal| UNMADE_VERBS.include?(Questions.question_for(refusal.node, console)&.verb) }
      end

      # WHAT .claude/dsl/playstation.md SAYS: every answer, in the order ANSWERS gives them, and what the
      # PlayStation's build does not make yet — +not_yet+, the lowering's own list of the program's kinds
      # it refuses for now, by what they are part of (Kit#answers_page).
      def self.reference(not_yet: {})
        <<~MARKDOWN
          # The PlayStation — what every verb does there

          A game built for the PlayStation too (`VBlank.game "NAME", consoles: %i[gba ps1]`, then
          `vblank build`, which makes a program for each console, or `--console ps1` for the
          PlayStation's alone) is the same game on another machine: a 320×240 screen (`screen_width`,
          `screen_height`), pictures drawn by its graphics chip, colours of fifteen bits and lists of
          256. The build makes a PS-X EXE, the file an emulator or a loader on a real console runs. Every
          verb has one of two answers there, decided once in `Console::PS1Answers`:

          - **works** — the same game, played the same way. The PlayStation lowering's run of
            `rake test:all` holds the program to the interpreter after every pass.
          - **refused** — the build stops before anything is made, naming the hardware the PlayStation
            lacks and what to use instead.

          This file is `Console::PS1Answers.reference` written out (`ruby tools/console_answers.rb`), and
          a test fails when the two differ. The Advance's answers are in `.claude/dsl/game-boy-advance.md`.

          #{answer_lines.join("\n")}

          ## Not made yet

          #{not_yet_words(not_yet)}
        MARKDOWN
      end

      # THE VERBS WHOSE STEPS THE BUILD DOES NOT MAKE YET, by the part of the build they wait on — the
      # parts of Backends::PS1::Lowering::NOT_LOWERED_YET, and the other parts it refuses by name
      # (Lowering#refuse_unmade_parts!). A verb is here when a game that uses it reaches a step of the
      # part; test_ps1_kind_coverage.rb holds the parts to the lowering's.
      VERBS_NOT_MADE_YET = Ractor.make_shareable({
        "the painted (bitmap) screen" => %i[draw_column_at camera camera_follows shake_screen],
        "fades, lights and screen effects" => %i[pixelate pixelate_in pixelate_out spotlight iris_in iris_out],
        "sprites and tiled backgrounds" => %i[canvas tile_pictures sprite_tiles picture_groups],
        "save memory" => %i[save_var save_data saves_keep_everything]
      })

      # What the page says of the steps the PlayStation's build does not make yet: for each part, the
      # verbs that wait on it and the steps it names in a refusal.
      def self.not_yet_words(not_yet)
        return "The build for the PlayStation makes every kind of step that the answers above do not refuse." if
          not_yet.empty?

        "An answer above is what the PlayStation does with a verb. The build for it is still growing,\n" \
          "and a game that reaches one of these steps is refused, naming the step, until it is made.\n\n" +
          not_yet.map do |part, kinds|
            verbs = VERBS_NOT_MADE_YET.fetch(part, []).map { |verb| "`#{verb}`" }.join(", ")
            "- #{part}: the verbs #{verbs}; the steps #{kinds.map { |kind| "`#{kind}`" }.join(', ')}"
          end.join("\n")
      end
    end
  end
end
