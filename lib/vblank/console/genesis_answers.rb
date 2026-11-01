# frozen_string_literal: true

module VBlank
  module Console
    # WHAT EVERY VERB DOES ON A SEGA GENESIS (Console::Answers says what an answer is).
    #
    # The Genesis is a 16-bit console of 1988 with a 68000 at its heart. Next to the Super Nintendo it
    # has a wider screen (320×224), fewer colours (512 to choose from, 64 on the screen at once, in
    # four lists of sixteen that sprites and backgrounds share) and fewer sprites (80, 20 on a row).
    # What it lacks is the Advance's painted screen (every picture is tiles), a sprite that turns or
    # resizes, any layer that turns, blending of one layer into another, and the Super Nintendo's
    # colour maths. It has two layers of tiles that scroll, a third (the window) that covers whole
    # rows of tiles, and a sound chip of two kinds: square voices and a noise voice (the PSG), and
    # six voices of frequency-modulated sound (the YM2612).
    #
    # A GAME SAYS WHICH CONSOLES IT IS FOR (`VBlank.game "PONG", consoles: %i[gba genesis]`), and is
    # laid out from `screen_width` and `screen_height` rather than from 240 and 160, so the same game
    # fills each screen.
    #
    # An answer here is what the console's hardware does. What the Genesis build does not make yet is
    # the lowering's own list (Backends::Genesis::Lowering::NOT_LOWERED_YET), which the page shows
    # under its own heading and the build refuses by name.
    module GenesisAnswers
      extend Answers

      PAGE = ".claude/dsl/sega-genesis.md"

      PLAIN = "the same as on the Advance."

      ANSWERS = Ractor.make_shareable({
        # --- building, the screen and settings ---
        screen: works("`screen :tiled` and `screen :bitmap` work. A Genesis has no painted screen, so a " \
                      "painted (bitmap) screen is made of tiles internally, which holds fifteen colours " \
                      "and black: a game that paints more is refused. `tear_free: true` keeps one " \
                      "picture, because the picture is copied to the console whole before it shows. " \
                      "`screen :rotozoom` is refused: a Genesis cannot turn a background."),
        setting: works,
        screen_width: works("320 on a Genesis."),
        screen_height: works("224 on a Genesis."),
        wait_vblank: works("in a game loop, the sprites and scroll of a pass show on the frame after the wait. " \
                           "If a game writes the wait in a scene or an `if`, they show a frame later than that."),
        halt: works,
        debug_halt: works("the game stops there, as `halt` does; the cartridge is not cut short."),
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
        clear_screen: works,
        inside: works,
        grid: works,
        camera: works("a painted screen is the size of the screen, so moving the view over it shows " \
                      "black past the picture's edge. To move over a bigger world, use a tiled " \
                      "background and `scroll_to`."),
        keep_showing: works("a painted screen is always shown whole, so a picture kept showing never tears."),

        # --- fades, tints and screen effects ---
        fade: works("`fade` and `tint` change the colours the console shows, not the picture: the colour " \
                    "memory is written again for each step, since a Genesis has no brightness control. " \
                    "`inside:`, `outside:` and `under:` are refused: the build cannot fade part of the " \
                    "screen on a Genesis."),
        tint: works,
        fade_in: works,
        fade_out: works,
        flash_screen: works,
        fade_level: works,
        shake_screen: works,
        pixelate: refused("a Genesis cannot show the screen in blocks: it has no mosaic. Use `fade_out` and " \
                          "`fade_in` to go from one screen to the next."),
        pixelate_in: refused("see `pixelate`."),
        pixelate_out: refused("see `pixelate`."),
        pixelate_size: works,
        spotlight: refused("a light darkens everything outside a circle by degrees, and a Genesis cannot mix " \
                           "or darken part of the screen. Use `fade` to darken the whole screen."),
        iris_in: refused("the iris is the game's light closing (see `spotlight`). Use `fade_out` and `fade_in`."),
        iris_out: refused("see `iris_in`."),
        iris_shut?: refused("see `iris_in`."),
        pulse: refused("a Genesis cannot resize a sprite. Draw the sprite's sizes as poses and `face` them in turn."),
        camera_follows: works,

        # --- pictures and sprites ---
        image: works("a sprite's picture and a background's tile hold fifteen colours and see-through, from " \
                     "lists of sixteen. The four lists are shared by the sprites and the backgrounds."),
        color: works("a colour has nine bits on a Genesis: three each of red, green and blue. A game names " \
                     "a colour in fifteen bits, and the Genesis shows the top three bits of each channel, " \
                     "as the interpreter does for the Genesis."),
        rgb: works("see `color`."),
        rgb8: works("see `color`."),
        colors: works("a list of colours holds sixteen places on a Genesis, the first see-through. The console " \
                      "holds four lists, for the sprites and the backgrounds together."),
        recolor: works("a list told to hold other colours keeps a palette to itself for the whole game, so " \
                       "a game can change the four lists."),
        color_walk: works,
        colors_in_use: works,
        mirror: works,
        upside_down: works,
        blit: works,
        sprite: works("a sprite is made of the console's pieces, 80 pieces at once and 20 pieces of 8×8 on " \
                      "any one row of the screen. Past 80 pieces, a sprite is not drawn and no error shows " \
                      "as the game runs. `scale`, `face_angle` and `turn` are refused: a Genesis cannot " \
                      "turn or resize a sprite. Draw the turns as poses."),
        draw_in_order: works,
        hide_sprites: works("on the next frame, no sprite shows. On the frame after, every sprite shows where it is."),
        picture_groups: works,
        pool: works("its sprites count towards the 80."),
        box: works,

        # --- backgrounds and layers ---
        tiles: works("tiles of fifteen colours each and see-through, from one of the four lists."),
        background: works("two backgrounds at a time, scrolled and changed as on the Advance. A background is " \
                          "at most 64 tiles across and 64 down, as on the Advance. `rotate` and `scale` are " \
                          "refused: a Genesis cannot turn a background. A `scroll_each_row` block runs for " \
                          "all 224 rows each pass."),
        status_bar: works("the bar is the window, a layer the console keeps beside its two backgrounds. " \
                          "`set_tile` with `now: true` is refused: a Genesis writes its video memory only " \
                          "between frames, so a change shows on the frame after the pass."),
        canvas: works,
        layers: works("a layer holds a background or sprites. A layer cannot be see-through: a Genesis " \
                      "cannot mix one layer into another, so `transparency:`, `shows:` and `shows_behind:` " \
                      "are refused."),
        layer: works("see `layers`."),

        # --- text ---
        draw_text: works("painted on a painted screen; on a tiled one each letter is a sprite, so they " \
                         "count towards the 80, 20 pieces to a row."),
        draw_number: works("see `draw_text`."),
        font: works,
        text_width: works,
        text_height: works,
        menu: works("see `draw_text` for what its rows are made of."),

        # --- numbers and logic ---
        var: works("a variable is the same 32-bit whole number as on the Advance."),
        save_var: works("kept in battery-backed RAM on the cartridge."),
        save_data: works("kept in battery-backed RAM on the cartridge."),
        clock: refused("a Genesis cartridge has no clock chip. Ask the player for the time on a screen of " \
                       "the game's own, if the game needs it."),
        saves_keep_everything: works,
        set: works, add: works, add_var: works,
        sub: works, sub_var: works, copy: works,
        negate: works, negate!: works, flip: works, flip!: works, abs: works, abs!: works,
        negate_abs: works, negate_abs!: works, clamp: works, clamp!: works,
        approach: works, approach!: works,
        list: works,
        if_eq: works, if_ne: works, if_gt: works, if_lt: works, if_ge: works, if_le: works,
        if_gte: works, if_lte: works,
        func: works("`fast:` means nothing on a Genesis, which runs all of its code alike."),
        call: works,
        scene: works("see `func` for `fast:`."),
        case_var: works,
        uses: works("a pack's verbs are verbs of the game's own, and each one has its answer here."),
        dump_func: refused("it lists the ARM a routine was made into, and a Genesis has no ARM processor to " \
                           "list it for."),
        entry: refused("`entry` is raw ARM for the Advance's processor, which a Genesis does not have."),

        # --- input ---
        held: works("the buttons a Genesis pad has: `:a`, `:b`, `:c`, `:start` and the D-pad. A Genesis pad has " \
                    "no `:select`, `:l`, `:r`, `:x` or `:y`: use `:c` and `:start` for them."),
        pressed: works("see `held`."),
        if_held: works("see `held`."),
        if_pressed: works("see `held`."),
        rumble: works("nothing is felt. A Genesis cartridge has no rumble motor, so the game plays the same " \
                      "without it."),

        # --- randomness ---
        seed: works, randomize: works, roll: works, rand: works, chance: works, random_numbers: works,

        # --- sound and music ---
        enable_sound: works,
        define_sound: works("a Genesis plays a square on its PSG, which has three square voices."),
        beep: works("see `define_sound`."),
        noise: works("a hiss is played on the PSG's noise voice."),
        wave: works("a Genesis has no wave voice: the six voices of its FM chip play each waveform as a tone " \
                    "of their own."),
        stop_wave: works,
        song: works("see `define_sound` for the square and wave voices."),
        play_song: works,
        stop_music: works,
        hold_music: works,
        release_music: works,
        music_volume: works,
        fade_music_in: works,
        fade_music_out: works,
        songs: works("see `song`."),
        sound_effects: works("see `song`."),
        sample: works("a recording is played on the FM chip's sixth voice, which can play a recording of eight " \
                      "bits. Only one recording plays at a time."),
        instrument: works("see `sample`.")
      })

      # WHAT .claude/dsl/sega-genesis.md SAYS: every answer, in the order ANSWERS gives them, and what
      # the Genesis's build does not make yet — +not_yet+, the lowering's own list of the program's
      # kinds it refuses for now, by what they are part of (Kit#answers_page).
      def self.reference(not_yet: {})
        <<~MARKDOWN
          # The Sega Genesis — what every verb does there

          A game built for the Genesis too (`VBlank.game "NAME", consoles: %i[gba genesis]`, then
          `vblank build`, which makes a cartridge for each console, or `--console genesis` for the
          Genesis's alone) is the same game on another machine: a 320×224 screen (`screen_width`,
          `screen_height`), 80 sprites (20 pieces on a row of the screen), backgrounds of tiles, colours
          of nine bits and four lists of sixteen. Every verb has one of two answers there, decided once
          in `Console::GenesisAnswers`:

          - **works** — the same game, played the same way. The Genesis lowering's run of
            `rake test:all` holds the cartridge to the interpreter after every pass.
          - **refused** — the build stops before anything is made, naming the hardware the Genesis
            lacks and what to use instead. Nothing is shown differently.

          This file is `Console::GenesisAnswers.reference` written out (`ruby tools/console_answers.rb`),
          and a test fails when the two differ. The Advance's answers are in
          `.claude/dsl/game-boy-advance.md`.

          #{answer_lines.join("\n")}

          ## Not made yet

          #{not_yet_words(not_yet)}
        MARKDOWN
      end

      # What the page says of the steps the Genesis's build does not make yet.
      def self.not_yet_words(not_yet)
        return "The build for the Genesis makes every kind of step that the answers above do not refuse." if
          not_yet.empty?

        "An answer above is what the Genesis does with a verb. The build for it is still growing,\n" \
          "and a game that reaches one of these steps is refused, naming the step, until it is made:\n\n" +
          not_yet.map { |part, kinds| "- #{part}: #{kinds.map { |kind| "`#{kind}`" }.join(', ')}" }.join("\n")
      end
    end
  end
end
