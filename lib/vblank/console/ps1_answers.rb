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
    # A GAME SAYS WHICH CONSOLES IT IS FOR (`VBlank.game "PONG", consoles: %i[gba ps1]`), and is laid out
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
                      "works too: the chip draws the turned background as a textured shape."),
        setting: works,
        built_for_computer?: works("false on a PlayStation."),
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
        shading: works("a shading is data in the program."),
        screen_spot: works("the processor turns and projects the point, as the drawing of a place does."),
        draw_place: works("the processor turns and projects every corner, and the graphics chip fills the faces."),
        clear_screen: works,
        inside: works,
        grid: works,
        camera: works,
        keep_showing: works,

        # --- fades, tints and screen effects ---
        fade: works("`fade` and `tint` change the colours the console shows. How the graphics chip fades part of " \
                    "the screen (`inside:`, `outside:`, `under:`) is decided when that is made: until then the " \
                    "build refuses it and says so."),
        tint: works,
        fade_in: works,
        fade_out: works,
        flash_screen: works,
        fade_level: works,
        shake_screen: works,
        pixelate: works("each block is the colour of one of its pixels, drawn by the graphics chip."),
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
        image: works("a picture is kept in video RAM, with a list of 16 or 256 colours."),
        color: works("a colour has fifteen bits, as on the Advance."),
        rgb: works("see `color`."),
        rgb8: works("see `color`."),
        colors: works("a list of colours holds 256 places on a PlayStation, the first see-through."),
        recolor: works,
        color_walk: works,
        colors_in_use: works,
        mirror: works,
        upside_down: works,
        blit: works,
        sprite: works("a sprite is a picture the graphics chip draws each frame, any size up to 256 × 256. There is " \
                      "no limit of sprites on a row of the screen. A sprite that turns or resizes is drawn as a " \
                      "textured shape."),
        draw_in_order: works,
        hide_sprites: works,
        picture_groups: works,
        pool: works,
        box: works,

        # --- backgrounds and layers ---
        tiles: works,
        background: works("a background is a picture kept in video RAM, drawn by the graphics chip at its scroll. " \
                          "`show_only_inside` holds it to the chip's drawing area, and a background that turns or " \
                          "resizes is drawn as a textured shape."),
        status_bar: works,
        canvas: works,
        tile_pictures: works,
        sprite_tiles: works,
        layers: works,
        layer: works("see `layers`."),

        # --- text ---
        draw_text: works,
        draw_number: works("see `draw_text`."),
        font: works,
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
        if_eq: works, if_ne: works, if_gt: works, if_lt: works, if_ge: works, if_le: works,
        if_gte: works, if_lte: works,
        func: works("`fast:` means nothing on a PlayStation, which runs all of its code alike."),
        call: works,
        scene: works("see `func` for `fast:`."),
        case_var: works,
        uses: works("a pack's verbs are verbs of the game's own, and each one has its answer here."),
        dump_func: refused("it lists the ARM a routine was made into, and a PlayStation has no ARM processor to list it for."),
        entry: refused("`entry` is raw ARM for the Advance's processor, which a PlayStation does not have."),

        # --- input ---
        held: works("a game names the pad's buttons by the shared names: `:a` is Cross, `:b` Circle, `:x` Triangle, " \
                    "`:y` Square, `:l` L1 and `:r` R1, with `:select`, `:start` and the D-pad. A PlayStation has two " \
                    "ports for pads. The build reads the first alone for now, so `player: 2` and `players:` more " \
                    "than 1 are not made yet."),
        pressed: works("see `held`."),
        if_held: works("see `held`."),
        if_pressed: works("see `held`."),
        most_players: works,
        drawing_for_local_player: works("the player is always 1: a console is played by one person."),
        mark: works,
        players_connected: works("1 while the build reads the first pad alone."),
        rumble: works("nothing is felt. The build reads a digital pad, which has no motor, so the game plays the " \
                      "same without it."),

        # --- randomness ---
        seed: works, randomize: works, roll: works, rand: works, chance: works, random_numbers: works,

        # --- sound and music ---
        enable_sound: works,
        define_sound: works("the sound chip plays a square as a short recording of one wave, on a voice of its own."),
        beep: works("see `define_sound`."),
        noise: works("the sound chip has a noise voice."),
        wave: works("the waveform is played as a short recording of one wave."),
        stop_wave: works,
        song: works,
        play_song: works,
        stop_music: works,
        hold_music: works,
        release_music: works,
        music_volume: works,
        fade_music_in: works,
        fade_music_out: works,
        songs: works,
        sound_effects: works("see `song`."),
        sample: works("the sound chip plays recordings itself, 24 voices of them, each with its own loudness."),
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
      # (Lowering#refuse_unmade_parts!). A verb is here when a game that says it reaches a step of the
      # part; test_ps1_kind_coverage.rb holds the parts to the lowering's.
      VERBS_NOT_MADE_YET = Ractor.make_shareable({
        "the painted (bitmap) screen" => %i[draw_column_at camera camera_follows shake_screen sprite],
        "fades, lights and screen effects" => %i[fade tint fade_in fade_out flash_screen pixelate pixelate_in
                                                 pixelate_out spotlight iris_in iris_out],
        "places drawn in 3D" => %i[draw_place],
        "sprites and tiled backgrounds" => %i[sprite tiles background status_bar canvas tile_pictures sprite_tiles
                                              layers layer draw_in_order hide_sprites picture_groups colors recolor
                                              color_walk],
        "sound" => %i[enable_sound define_sound beep noise wave stop_wave song play_song stop_music hold_music
                      release_music music_volume fade_music_in fade_music_out songs sound_effects sample instrument],
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
