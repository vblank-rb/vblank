# frozen_string_literal: true

require "test_helper"
require "web_page"

# createGame(host): the game as something a page makes, as many times as it likes, rather than a
# script that starts itself. Every output of the web build — the page, the module, the classic
# script — is a caller of it. These pages are written by hand around JS#factory, as somebody's own
# page would be, and played in the stand-in browser (WebPage).
class TestJSCreateGame < Minitest::Test
  include WebPage
  JS = VBlank::IR::Backends::JS

  # A page of +canvases+ (their ids) that runs +host_js+ once createGame is defined. +host_js+
  # keeps what it makes in `games`, where a step can reach it (`js games[0].pause()`). With +data+
  # :separate, the game's big tables are to be fetched from game.data beside the page.
  private def page_of(game, canvases, host_js, data: :inline)
    factory, = JS.new.factory_and_data_file(game.program, title: game.title, data: data)
    <<~HTML
      <!doctype html>
      #{canvases.map { |id| %(<canvas id="#{id}" width="240" height="160"></canvas>) }.join("\n")}
      <script>
      (function () {
      "use strict";
      const rg_data_beside = "game.data";
      #{factory}
      #{host_js}
      })();
      </script>
    HTML
  end

  private def canvas(id) = %(document.getElementById("#{id}"))

  # Given nothing but a canvas, a game plays as the page plays it: the keyboard, the frames, the
  # picture.
  def test_a_host_given_only_a_canvas_plays_like_the_page
    html = page_of(walking_game, %w[one], "window.games = [createGame({ canvas: #{canvas('one')} })];")
    mine = pictures_in(played_page(["down ArrowRight", "play 10", "picture one"], html: html)).first
    page = pictures_in(played_page(["down ArrowRight", "play 10", "picture"])).first

    assert_same_picture page, mine, "after ten frames holding right"
  end

  # Each createGame is a game of its own: two on one page keep their own state, and pausing one
  # leaves the other playing.
  def test_two_games_on_one_page_play_apart
    html = page_of(ticking_game, %w[one two],
                   "window.games = [createGame({ canvas: #{canvas('one')} }), createGame({ canvas: #{canvas('two')} })];")
    lines = played_page(["play 3", "js games[1].pause()", "play 5", "picture one", "picture two"], html: html)
    one, two = pictures_in(lines)
    eight, three = [8, 3].map { |frames| pictures_in(played_page(["play #{frames}", "picture"], ticking_game)).first }

    assert_same_picture eight, one, "of the game left playing"
    assert_same_picture three, two, "of the game paused after three frames"
  end

  # The handle presses the console's buttons by name, as a page's own on-screen pad would.
  def test_the_handle_presses_buttons_by_name
    html = page_of(walking_game, %w[one], "window.games = [createGame({ canvas: #{canvas('one')} })];")
    pressed = pictures_in(played_page(['js games[0].press("right")', "play 10", "picture one"], html: html)).first
    keyed = pictures_in(played_page(["down ArrowRight", "play 10", "picture"])).first

    assert_same_picture keyed, pressed, "after ten frames with right pressed"
  end

  # A host can leave the keyboard alone: a page with a game of its own in a text editor's
  # neighbourhood, say.
  def test_a_host_can_turn_the_keyboard_off
    html = page_of(walking_game, %w[one], "window.games = [createGame({ canvas: #{canvas('one')}, keys: false })];")
    still = pictures_in(played_page(["down ArrowRight", "play 10", "picture one"], html: html)).first
    untouched = pictures_in(played_page(["play 10", "picture"])).first

    assert_same_picture untouched, still, "with the keyboard off and right held"
  end

  # What the page says in words — a game that went wrong, a controller — goes to the host's
  # onMessage, which the page's own notes are one use of.
  def test_a_game_that_goes_wrong_tells_the_host
    game = VBlank.game "FULL", consoles: %i[gba] do
      screen :bitmap
      trail = list :trail, capacity: 2
      game_loop { trail.push 1 }
    end
    html = page_of(game, %w[one], <<~JS)
      window.said = [];
      window.games = [createGame({ canvas: #{canvas('one')}, onMessage: (kind, text) => said.push(`${kind}: ${text}`) })];
    JS
    told = played_page(["play 5", 'js said.join(" | ")'], html: html).grep(/\Ajs /).first

    assert_match(/stopped: The game stopped: .*list :trail is full/, told)
  end

  # A stopped game lets go of the page: its keys go back to the page (the arrows scroll again, F
  # does nothing), and a save not yet written is written as it stops.
  def test_a_stopped_game_lets_go_of_the_page_and_keeps_its_save
    game = VBlank.game "KEEPER", consoles: %i[gba] do
      screen :bitmap
      count = save_var :count, 0
      game_loop { count += 1 }
    end
    html = page_of(game, %w[one], <<~JS)
      window.kept = [];
      const storage = { getItem: () => null, setItem: (key) => kept.push(key) };
      window.games = [createGame({ canvas: #{canvas('one')}, storage })];
    JS
    lines = played_page(["play 3", "js games[0].stop()", "down ArrowRight", "down KeyF", "state", 'js kept.join(",")'], html: html)

    assert_includes lines, "state audio=none fullscreen=none kept=0"
    assert_includes lines, "js vblank-save:KEEPER"
  end

  # The handle reads the save memory as it stands and writes it — a page's own "export my save" and
  # "import a save" — and refuses bytes that are not the size of the game's save memory.
  def test_the_handle_reads_and_writes_the_save
    game = VBlank.game "KEEPER", consoles: %i[gba] do
      screen :bitmap
      count = save_var :count, 0
      game_loop { count += 1 }
    end
    html = page_of(game, %w[one], "window.games = [createGame({ canvas: #{canvas('one')}, storage: null })];")
    lines = played_page(["play 3", "js window.first = games[0].readSave(); first.length > 0 && first.some((byte) => byte !== 0xFF)",
                         "js games[0].writeSave(new Uint8Array(first.length).fill(7)); games[0].readSave().every((byte) => byte === 7)",
                         "js try { games[0].writeSave(new Uint8Array(3)); 'kept' } catch (error) { error.message }"], html: html)

    assert_equal ["js true", "js true"], lines.grep(/\Ajs /).first(2)
    assert_match(/must be \d+ bytes/, lines.grep(/\Ajs /).last)
  end

  # A click on a paused game makes the sound ready but keeps it waiting: it plays when the game does.
  def test_a_click_while_paused_keeps_the_sound_waiting
    html = page_of(ticking_game, %w[one], "window.games = [createGame({ canvas: #{canvas('one')} })];")
    lines = played_page(["play 2", "blur", "click one", "state", "focus", "state"], html: html)

    assert_equal %w[suspended running], lines.grep(/\Astate /).map { |line| line[/audio=(\S+)/, 1] }
  end

  # Data given in a form the game cannot read is said to be that, in words that say what to give.
  def test_data_it_cannot_read_is_said_in_plain_words
    html = page_of(walking_game, %w[one], <<~JS, data: :separate)
      window.said = [];
      window.games = [createGame({ canvas: #{canvas('one')}, data: {}, onMessage: (kind, text) => said.push(text) })];
    JS
    told = played_page(["play 3", 'js said.join(" | ")'], html: html).grep(/\Ajs /).first

    assert_match(/cannot read the data.*address, or its bytes/, told)
  end

  # A host's own key layout takes the place of the window's: D is right here, and the arrows are
  # nothing.
  def test_a_host_can_lay_the_keys_out_its_own_way
    html = page_of(walking_game, %w[one], "window.games = [createGame({ canvas: #{canvas('one')}, keyMap: { KeyD: \"right\" } })];")
    by_d = pictures_in(played_page(["down KeyD", "play 10", "picture one"], html: html)).first
    by_arrow = pictures_in(played_page(["down ArrowRight", "play 10", "picture one"], html: html)).first

    assert_same_picture walked_right, by_d, "with D held as right"
    assert_same_picture stood_still, by_arrow, "with the arrow held, which this layout leaves out"
  end

  # Keys heard on one element (a canvas given tabindex) are not heard on the rest of the page, so
  # two games on one page each hear only their own.
  def test_a_host_can_hear_keys_on_one_element_only
    html = page_of(walking_game, %w[one], "window.games = [createGame({ canvas: #{canvas('one')}, keyTarget: #{canvas('one')} })];")
    lines = played_page(["down ArrowRight", "play 10", "picture one", "state"], html: html)

    assert_same_picture stood_still, pictures_in(lines).first, "with right pressed elsewhere on the page"
    assert_includes lines, "state audio=none fullscreen=none kept=0"
  end

  # Turned off, the F key, controllers and sound are each left alone.
  def test_a_host_can_turn_off_the_f_key_controllers_and_sound
    html = page_of(walking_game, %w[one], <<~JS)
      window.said = [];
      window.games = [createGame({ canvas: #{canvas('one')}, fullscreenKey: null, gamepads: false, audio: false,
                                   onMessage: (kind, text) => said.push(kind) })];
    JS
    lines = played_page(["pad connect", "pad press 15", "down KeyF", "play 10", "picture one", "state", 'js said.join(",")'],
                        html: html)

    assert_same_picture stood_still, pictures_in(lines).first, "with the controller's right held and controllers off"
    assert_includes lines, "state audio=none fullscreen=none kept=0"
    refute_includes lines.grep(/\Ajs /).first.to_s, "controller"
  end

  # A game made with autostart false plays nothing until start, and then plays from its first
  # frame; ready settles once it can play.
  def test_a_host_can_start_the_game_when_it_chooses
    html = page_of(ticking_game, %w[one], <<~JS)
      window.games = [createGame({ canvas: #{canvas('one')}, autostart: false })];
      games[0].ready.then(() => { window.isReady = true; });
    JS
    lines = played_page(["play 5", "js games[0].start()", "play 4", "picture one", "js isReady"], html: html)
    four = pictures_in(played_page(["play 4", "picture"], ticking_game)).first

    assert_same_picture four, pictures_in(lines).first, "four frames after start, with five before it"
    assert_includes lines, "js true"
  end

  # The save is kept under the name the host gives, in place of the game's.
  def test_a_host_can_name_the_save
    game = VBlank.game "SAVER", consoles: %i[gba] do
      screen :bitmap
      count = save_var :count, 0
      count += 1
      halt
    end
    html = page_of(game, %w[one], <<~JS)
      window.kept = [];
      const storage = { getItem: () => null, setItem: (key) => kept.push(key) };
      window.games = [createGame({ canvas: #{canvas('one')}, storage, saveKey: "my-own-slot" })];
    JS

    assert_includes played_page(["play 3", 'js kept.join(",")'], html: html), "js my-own-slot"
  end

  private def walked_right = pictures_in(played_page(["down ArrowRight", "play 10", "picture"])).first
  private def stood_still = pictures_in(played_page(["play 10", "picture"])).first

  # The save goes where the host says, under the game's name unless the host names it.
  def test_the_save_goes_where_the_host_keeps_it
    game = VBlank.game "SAVER", consoles: %i[gba] do
      screen :bitmap
      count = save_var :count, 0
      count += 1
      halt
    end
    html = page_of(game, %w[one], <<~JS)
      window.kept = [];
      const storage = { getItem: () => null, setItem: (key, value) => kept.push(key) };
      window.games = [createGame({ canvas: #{canvas('one')}, storage })];
    JS

    assert_includes played_page(["play 3", 'js kept.join(",")'], html: html), "js vblank-save:SAVER"
  end

  # --- the frames: what is drawn, and what is asked of the browser ---

  private def ticking_page = page_of(ticking_game, %w[one], "window.games = [createGame({ canvas: #{canvas('one')} })];")

  private def counted(lines, what) = lines.grep(/\Acounts/).map { |line| line[/#{what}=(\d+)/, 1].to_i }

  # A page that was busy owes frames, plays every one of them so the game is where it should be, and
  # puts only the last picture on the canvas: the others were never to be seen. Nine frames in all
  # here, the last six of them owed at once.
  def test_a_page_that_is_behind_plays_every_frame_it_owes_and_draws_only_the_last
    lines = played_page(["play 3", "counts", "skip 5", "play 1", "counts", "picture one"], html: ticking_page)
    before, after = counted(lines, "pictures")
    steady = pictures_in(played_page(["play 9", "picture one"], html: ticking_page)).first

    assert_equal 1, after - before, "six frames were owed and one picture was put on the canvas"
    assert_same_picture steady, pictures_in(lines).first, "after nine frames, six of them played at once"
  end

  # A game that ends partway through the frames it owes still leaves its last picture up, though the
  # frames before it were not drawn.
  def test_a_game_that_ends_among_the_frames_it_owes_leaves_its_last_picture_up
    ending = VBlank.game "ENDING", consoles: %i[gba] do
      screen :bitmap
      x = var :x, 0
      game_loop do
        x += 1
        clear_screen :black
        draw_rect_at x, 20, 4, 4, :green
        halt if x == 4
      end
    end
    html = page_of(ending, %w[one], "window.games = [createGame({ canvas: #{canvas('one')} })];")
    lines = played_page(["play 1", "skip 10", "play 1", "picture one"], html: html)
    last = Reference.new.run(ending.program, frames: 50).screen.shown

    assert_same_picture last, pictures_in(lines).first, "of a game that ended on its fourth frame, with the first three owed at once"
  end

  # A game that stops leaves its last picture up, however it stops: by halting, or by running off
  # its end.
  def test_a_game_that_runs_off_its_end_among_the_frames_it_owes_leaves_its_last_picture_up
    running_out = VBlank.game "RUNNINGOUT", consoles: %i[gba] do
      screen :bitmap
      x = var :x, 0
      repeat(4) do
        x += 1
        clear_screen :black
        draw_rect_at x, 20, 4, 4, :green
        wait_vblank
      end
    end
    html = page_of(running_out, %w[one], "window.games = [createGame({ canvas: #{canvas('one')} })];")
    lines = played_page(["play 1", "skip 10", "play 1", "picture one"], html: html)
    steady = pictures_in(played_page(["play 10", "picture one"], html: html)).first

    assert_same_picture steady, pictures_in(lines).first, "of a game that ran off its end, with the frames before it owed at once"
  end

  # A picture that is the one already on the canvas is not put there again.
  def test_a_picture_that_has_not_changed_is_not_put_on_the_canvas_again
    still = VBlank.game "STILL", consoles: %i[gba] do
      screen :bitmap
      clear_screen :blue
      game_loop {}
    end
    html = page_of(still, %w[one], "window.games = [createGame({ canvas: #{canvas('one')} })];")

    assert_equal [1], counted(played_page(["play 20", "counts"], html: html), "pictures")
  end

  # A paused game asks the browser for no more frames, however long it is paused, and goes on from
  # where it stood when the pause ends, however it ends: the page's own pause and resume, the
  # keyboard going and coming back, and the page ceasing to pause for a window that has lost it.
  def test_a_paused_game_asks_for_no_frames_and_goes_on_from_where_it_stood
    {
      "the page's own resume" => ["js games[0].pause()", "play 2", "counts", "play 30", "counts", "js games[0].resume()"],
      "the keyboard coming back" => ["blur", "play 2", "counts", "play 30", "counts", "focus"],
      "no longer pausing for the keyboard" => ["blur", "play 2", "counts", "play 30", "counts",
                                              "js games[0].setPauseWhenUnfocused(false)"]
    }.each do |how, steps|
      lines = played_page(["play 4", *steps, "play 3", "picture one"], html: ticking_page)
      at_two_frames, at_thirty_two = counted(lines, "frames")
      steady = pictures_in(played_page(["play 7", "picture one"], html: ticking_page)).first

      assert_equal at_two_frames, at_thirty_two, "no frame is asked for while it is paused (#{how})"
      assert_same_picture steady, pictures_in(lines).first, "four frames, the pause, and three more (#{how})"
    end
  end

  # A game that stops leaves nothing running: no frame is left asked for.
  def test_a_stopped_game_leaves_no_frame_asked_for
    lines = played_page(["play 3", "js games[0].stop()", "play 5", "counts", "play 20", "counts"], html: ticking_page)
    stopped_at, later = counted(lines, "frames")

    assert_equal stopped_at, later
  end

  # --- the sound: played by a worklet where there is one, and by buffers where there is not ---

  # A steady square wave on the first voice, from the fourth frame on.
  private def beeping_game
    VBlank.game "BEEPING", consoles: %i[gba] do
      screen :bitmap
      enable_sound
      count = var :count, 0
      game_loop do
        count += 1
        beep 440, duty: :half, decay: :none, volume: 15 if count == 4
      end
    end
  end

  private def beeping_page(audio: nil)
    host = audio ? ", audio: #{audio}" : ""
    page_of(beeping_game, %w[one], "window.games = [createGame({ canvas: #{canvas('one')}#{host} })];")
  end

  # +frames+ browser frames, with the audio thread asking for what the speaker plays between each, as
  # it does all the time: a frame's sound is 800 samples, which is six and a quarter of its 128.
  private def playing(frames) = Array.new(frames) { ["play 1", "speaker 6"] }.flatten

  private def numbers_in(lines, what) = lines.grep(/\A#{what} /).first.split(" ", 3).last.to_s.split(",").map(&:to_f)

  # How many times a second the wave goes from low to high, across the part of it that sounds.
  private def cycles_a_second(samples, rate)
    sounding = samples.each_index.select { |i| samples[i].abs > 0.001 }
    wave = samples[sounding.first..sounding.last]
    high = wave.map { |sample| sample > samples.max / 2 }
    high.each_cons(2).count { |before, after| !before && after } * rate.to_f / wave.length
  end

  # With a worklet the sound is handed to it a frame at a time and plays from its ring, at the game's
  # own rate on a device made for it, sample for sample, and no buffer is made for any frame.
  def test_the_sound_plays_through_the_worklet_sample_for_sample
    lines = played_page(["click one", *playing(30), "speaker 40", "heard", "posted", "counts"], html: beeping_page)
    heard = numbers_in(lines, "heard")
    posted = numbers_in(lines, "posted")
    started = heard.index { |sample| sample.abs > 0.001 }

    refute_nil started, "the speaker should have put out the beep"
    assert_equal 0, counted(lines, "buffers").first, "no buffer is made for a frame"
    assert_equal posted.drop(posted.index { |sample| sample.abs > 0.001 }).first(2000), heard.drop(started).first(2000),
                 "what the speaker puts out is the frames' sound, in order, with nothing added or lost"
  end

  # The sound is at the right pitch on a device made for the game's rate and on one a host handed in at
  # another: the worklet reads between the game's samples to make each one the device is given.
  def test_the_sound_is_at_the_right_pitch_on_a_device_of_any_rate
    [48_000, 44_100, 96_000].each do |rate|
      html = beeping_page(audio: "new AudioContext({ sampleRate: #{rate} })")
      lines = played_page(["play 3", *playing(40), "speaker 400", "heard"], html: html)

      assert_in_delta 440.0, cycles_a_second(numbers_in(lines, "heard"), rate), 440 * 0.03, "a beep of 440 on a device of #{rate} a second"
    end
  end

  # A page that is not a secure context has no worklet, and a content security policy can refuse
  # one's code: each plays a frame's sound the old way, as a buffer of its own.
  def test_a_page_where_a_worklet_cannot_load_plays_the_sound_in_buffers
    %w[no-worklet refuse-worklet].each do |why|
      lines = played_page(["click one", "play 30", "counts", "play 30", "counts"], html: beeping_page, browser: [why])
      early, later = counted(lines, "buffers")

      assert_operator later, :>, early, "the sound goes on in buffers (#{why})"
      assert_operator early, :>, 0, "and began as soon as the worklet was known not to load (#{why})"
    end
  end

  # Nothing is made of a frame's sound until somebody has clicked or pressed a key: a browser plays
  # nothing till then.
  def test_no_sound_is_sent_before_a_click
    lines = played_page(["play 30", "posted", "counts"], html: beeping_page)

    assert_equal [0], counted(lines, "buffers")
    assert_equal "posted 0 ", lines.grep(/\Aposted /).first
  end

  # The sound waits with a game that is paused: the device is suspended, the worklet is not asked for
  # any, and when the game goes on the sound goes on from where it was.
  def test_the_sound_waits_with_a_game_that_is_paused
    lines = played_page(["click one", *playing(30), "speaker 20", "heard", "blur", "speaker 20", "heard", "focus", "play 5",
                         "speaker 20", "heard"], html: beeping_page)
    before, during, after = lines.grep(/\Aheard /).map { |line| line.split(" ")[1].to_i }

    assert_equal before, during, "nothing is played while the device is suspended"
    assert_operator after, :>, during, "and it plays again once the game does"
  end
end
