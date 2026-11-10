# frozen_string_literal: true

module VBlank
  module Console
    # WHAT EVERY VERB DOES ON DOS (Console::Answers says what an answer is).
    #
    # DOS is a PC of 1990 or so: a 386 in real mode, a VGA card of 256 colours and 320 × 200 pixels, an
    # AdLib for music and a Sound Blaster for recordings. The VGA card has no tiles and no sprites: it
    # shows a picture kept in its memory, and the processor writes every pixel of it. So a sprite is
    # pixels the processor copies, a background is a picture the processor draws, and the limit of
    # sprites is time, not a table. Its colours are a palette of 256, each six bits a channel. It has a
    # clock chip, and its keyboard stands for the pad.
    #
    # A GAME NAMES WHICH CONSOLES IT IS FOR (`VBlank.game "PONG", consoles: %i[gba dos]`), and is laid out
    # from `screen_width` and `screen_height` rather than from 240 and 160, so the same game fills each
    # screen.
    #
    # An answer here is what the console's hardware does. What the DOS build does not make yet is the
    # lowering's own list (Backends::DOS::Lowering::NOT_LOWERED_YET), which the page shows under its own
    # heading and the build refuses by name.
    module DOSAnswers
      extend Answers

      PAGE = ".claude/dsl/dos.md"

      PLAIN = "the same as on the Advance."

      ANSWERS = Ractor.make_shareable({
        # --- building, the screen and settings ---
        screen: works("`screen :bitmap` and `screen :tiled` work: the processor draws both into a picture in " \
                      "memory that the VGA card shows. The game's screen is the card's whole picture, 320 × 200 " \
                      "in mode 13h (the variants :mode_x and :vesa_640x480 are 320 × 240 and 640 × 480), so a " \
                      "game laid out from `screen_width` and `screen_height` fills it. A painted picture has a " \
                      "colour of fifteen bits in each pixel, kept as one of 256 colours in the card's palette. " \
                      "`tear_free: true` keeps two pictures, one drawn while the other shows. `screen :rotozoom` " \
                      "works too: the processor draws the turned background. `pixel_size: 2` is refused: the " \
                      "build does not show a painted screen bigger yet."),
        setting: works,
        built_for_computer?: works("false on DOS."),
        built_for?: works("true when asked about :dos."),
        screen_width: works("320 on DOS, or what the variant says."),
        screen_height: works("200 on DOS, or what the variant says."),
        border: works("it does nothing on DOS, which shows the game's screen whole."),
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
        dma_fill_rect: works("the processor fills the rectangle: DOS has no DMA copy for the picture."),
        draw_rect_at: works,
        draw_column_at: works,
        place: works("a place is data in the program."),
        viewer: works("a viewer is variables."),
        change_picture: works("every picture the place lists is in memory from the start, so a change copies nothing."),
        shading: works("a shading is data in the program."),
        screen_spot: works("the processor turns and projects the point, as the drawing of a place does."),
        draw_place: works("the processor turns and projects every corner and fills each face itself, as the " \
                          "interpreter does, with the same rule for which pixels a face covers."),
        clear_screen: works,
        inside: works,
        grid: works,
        camera: works,
        keep_showing: works,

        # --- fades, tints and screen effects ---
        fade: works("`fade` and `tint` change the palette the card shows, so the whole picture changes at once. " \
                    "How a fade of part of the screen (`inside:`, `outside:`, `under:`) is made is decided when " \
                    "that is made: until then the build refuses it and says so."),
        tint: works("see `fade`."),
        fade_in: works,
        fade_out: works,
        flash_screen: works,
        fade_level: works,
        shake_screen: works,
        pixelate: works("each block is the colour of one of its pixels, drawn by the processor."),
        pixelate_in: works("see `pixelate`."),
        pixelate_out: works("see `pixelate`."),
        pixelate_size: works,
        spotlight: works("how the processor darkens everything outside a circle is decided when the light is made: " \
                         "until then the build refuses a light and says so."),
        iris_in: works("the iris is the game's light closing (see `spotlight`)."),
        iris_out: works("see `iris_in`."),
        iris_shut?: works("see `iris_in`."),
        pulse: works("the processor draws the sprite bigger or smaller."),
        camera_follows: works,

        # --- pictures and sprites ---
        image: works("a picture is kept in memory, a byte a pixel, each a number into the card's palette of 256 " \
                     "colours. Pictures share the palette where their colours fit. A game whose pictures need more " \
                     "colours than the palette holds is refused when it is built. A game whose pictures do not fit " \
                     "in the 640K of memory beside the program is refused when it is built."),
        color: works("a colour has fifteen bits, as on the Advance. The card shows six bits of each channel, so " \
                     "every colour the game names is shown whole."),
        rgb: works("see `color`."),
        rgb8: works("see `color`."),
        colors: works("a list of colours holds 256 places on DOS, which is the card's whole palette."),
        recolor: works("the palette changes, so every pixel of that colour changes at once."),
        color_walk: works,
        colors_in_use: works,
        mirror: works,
        upside_down: works,
        blit: works,
        sprite: works("a sprite is a picture the processor draws each frame, any size up to 256 × 256, front-most " \
                      "last. The limit is time: the build counts 256 shown at once. A sprite that turns or resizes " \
                      "is drawn by the processor too."),
        draw_in_order: works,
        hide_sprites: works,
        picture_groups: works,
        pool: works,
        box: works,

        # --- backgrounds and layers ---
        tiles: works,
        background: works("a background is a picture kept in memory, drawn by the processor at its scroll. " \
                          "`show_only_inside` holds it to a rectangle, and a background that turns or resizes is " \
                          "drawn by the processor too."),
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
        save_var: works("kept in a file beside the program."),
        save_data: works("kept in a file beside the program."),
        part: works, start_over: works,
        clock: works("the PC's clock chip keeps the date and the time."),
        saves_keep_everything: works,
        set: works, add: works, add_var: works,
        sub: works, sub_var: works, copy: works,
        negate: works, negate!: works, flip: works, flip!: works, abs: works, abs!: works,
        negate_abs: works, negate_abs!: works, clamp: works, clamp!: works,
        approach: works, approach!: works,
        list: works,
        func: works("`fast:` means nothing on DOS, which runs all of its code alike."),
        call: works,
        scene: works("see `func` for `fast:`."),
        case_var: works,
        uses: works("a pack's verbs are verbs of the game's own, and each one has its answer here."),
        data_pack: works("the program holds what each slot holds, as if the game had written it."),
        dump_func: refused("it lists the ARM a routine was made into, and a PC has no ARM processor to list it for."),
        entry: refused("`entry` is raw ARM for the Advance's processor, which a PC does not have."),

        # --- input ---
        held: works("a game names the pad's buttons by the shared names: `:a` is Ctrl, `:b` Alt, `:l` Z, `:r` X, " \
                    "`:start` Enter, `:select` Right Shift, and the arrows are the D-pad. There is no `:x` or `:y`, " \
                    "and no joystick: the build reads the keyboard alone. `player: 2` is refused."),
        pressed: works("see `held`."),
        most_players: works,
        drawing_for_local_player: works("the player is always 1: a console is played by one person."),
        mark: works,
        players_connected: works("1."),
        rumble: works("nothing is felt. A keyboard has no motor, so the game plays the same without it."),

        # --- randomness ---
        seed: works, randomize: works, roll: works, rand: works, chance: works, random_numbers: works,

        # --- sound and music ---
        enable_sound: works("an AdLib card for music and effects, and a Sound Blaster for recordings."),
        define_sound: works("a square is an FM voice of the AdLib's chip with a plain wave."),
        beep: works("see `define_sound`."),
        noise: works("the AdLib has no noise voice. The processor mixes a hiss into the recordings the Sound Blaster plays."),
        wave: works("the waveform is played as a short recording of one wave on the Sound Blaster."),
        stop_wave: works,
        song: works("a song is played by the AdLib's nine FM voices."),
        play_song: works,
        stop_music: works,
        hold_music: works,
        release_music: works,
        music_volume: works,
        fade_music_in: works,
        fade_music_out: works,
        songs: works,
        sound_effects: works("see `song`."),
        sample: works("the processor mixes recordings, up to eight at a time, each with its own loudness, and the " \
                      "Sound Blaster plays the mix."),
        instrument: works("see `sample`.")
      })

      # The verbs whose refused part is the build's limit and not the console's: a fade of part of the screen
      # asks a console that blends (Console::Questions), and how the processor does it is decided when it
      # is made. Until then the lowering refuses it as not made yet (Backends::DOS::Lowering::NOT_LOWERED_YET), never in the words of hardware the console lacks.
      UNMADE_VERBS = %i[fade].freeze

      # Answers#refusals, less the lines whose verb is one of UNMADE_VERBS.
      def self.refusals(nodes, console)
        super.reject { |refusal| UNMADE_VERBS.include?(Questions.question_for(refusal.node, console)&.verb) }
      end

      # WHAT .claude/dsl/dos.md SAYS: every answer, in the order ANSWERS gives them, and what the
      # DOS build does not make yet — +not_yet+, the lowering's own list of the program's kinds
      # it refuses for now, by what they are part of (Kit#answers_page).
      def self.reference(not_yet: {})
        <<~MARKDOWN
          # DOS — what every verb does there

          A game built for DOS too (`VBlank.game "NAME", consoles: %i[gba dos]`, then `vblank build`,
          which makes a program for each console, or `--console dos` for DOS's alone) is the same game on
          another machine: a 320×200 screen (`screen_width`, `screen_height`; `variants: { dos: :mode_x }`
          is 320×240 and `variants: { dos: :vesa_640x480 }` is 640×480), pictures the processor draws,
          colours of fifteen bits and lists of 256. A frame is one vertical retrace of the card: 70 a
          second in mode 13h, 60 in the taller modes. The build makes an MZ EXE, the file DOS loads and
          DOSBox runs. Every verb has one of two answers there, decided once in `Console::DOSAnswers`:

          - **works** — the same game, played the same way. The DOS lowering's run of `rake test:all`
            holds the program to the interpreter after every pass.
          - **refused** — the build stops before anything is made, naming the hardware a PC lacks and
            what to use instead.

          This file is `Console::DOSAnswers.reference` written out (`ruby tools/console_answers.rb`), and
          a test fails when the two differ. The Advance's answers are in `.claude/dsl/game-boy-advance.md`.

          #{answer_lines.join("\n")}

          ## Not made yet

          #{not_yet_words(not_yet)}
        MARKDOWN
      end

      # THE VERBS WHOSE STEPS THE BUILD DOES NOT MAKE YET, by the part of the build they wait on — the
      # parts of Backends::DOS::Lowering::NOT_LOWERED_YET, and the other parts it refuses by name
      # (Lowering#refuse_unmade_parts!). A verb is here when a game that uses it reaches a step of the
      # part; the lowering's coverage test holds the parts to the lowering's.
      NOT_MADE_YET_PART = "everything past numbers, the game loop and a painted screen of pixels"

      VERBS_NOT_MADE_YET = Ractor.make_shareable({
        NOT_MADE_YET_PART => ANSWERS.keys - %i[setting built_for_computer? built_for? screen_width screen_height
                                               border halt debug_halt game_loop once_a_frame frames_since_power_on
                                               each_pass repeat wait_vblank screen clear_screen pixel color rgb rgb8
                                               var set add add_var sub sub_var copy]
      })

      # What the page says of the steps the DOS build does not make yet: for each part, the
      # verbs that wait on it and the steps it names in a refusal.
      def self.not_yet_words(not_yet)
        return "The build for DOS makes every kind of step that the answers above do not refuse." if
          not_yet.empty?

        "An answer above is what DOS does with a verb. The build for it is still growing,\n" \
          "and a game that reaches one of these steps is refused, naming the step, until it is made.\n\n" +
          not_yet.map do |part, kinds|
            verbs = VERBS_NOT_MADE_YET.fetch(part, []).map { |verb| "`#{verb}`" }.join(", ")
            "- #{part}: the verbs #{verbs}; the steps #{kinds.map { |kind| "`#{kind}`" }.join(', ')}"
          end.join("\n")
      end
    end
  end
end
