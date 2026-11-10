/*
 * The runtime in a browser: the picture in a <canvas>, the keyboard and any controller as the
 * gamepad, the sound through Web Audio, and the save memory kept between visits. The native
 * runtime's window (rg_sdl.c) does the same with SDL, and the frame goes the same way here: the
 * frame's sound is played, the next frame begins, its picture is shown, and its buttons are read.
 *
 * A browser cannot be made to wait inside a script, so the game is asked for one frame at a time
 * (rg_game_main, which carries on from where it stopped; see Printer), whenever the browser is about to draw — about sixty times a
 * second, more on a faster monitor, so a frame of the game is played only once a sixtieth of a
 * second has gone by since the last.
 *
 * THIS FILE IS INSIDE createGame(host) (see JS#factory), so each game made has all of it — and
 * every game's state — to itself. Everything it uses that a page might want otherwise comes from
 * +host+, and everything left out is what a page of its own would want:
 *
 *   canvas             where the picture goes: the one thing a host must give
 *   keys               false to leave the keyboard alone (true)
 *   keyTarget          what to hear keys on (the window); a canvas given tabindex="0" keeps two
 *                      games on one page from hearing each other
 *   keyMap             { browser key code: button name } in place of PAGE_KEYS
 *   menu               true for the window menu, hotkeys and remembered settings of a computer's
 *                      build (rg_page_menu.js), over +keyMap+; the page VBlank writes sets it
 *   gamepads           false to leave controllers alone (true)
 *   storage            where the save is kept: anything with getItem and setItem (the browser's
 *                      localStorage), or null to keep nothing
 *   saveKey            the name it is kept under ("vblank-save:" and the game's title)
 *   audio              false for no sound, or a Web Audio context of the host's (one made on the
 *                      first key or click, as a browser allows)
 *   fullscreenKey      the key that fills the screen ("KeyF"), or null for none
 *   fullscreenElement  what fills the screen (the canvas): a part of the page holding the canvas
 *                      and whatever else has to come with it, such as buttons on the screen
 *   pauseWhenUnfocused false to play on while another window has the keyboard (true)
 *   autostart          false to wait for start() (true)
 *   startFile          the bytes (a Uint8Array) of the file a game reads as it starts, if it reads one
 *   uncapped           true to play as fast as the page can go, showing the last picture of each batch
 *   menuOpen           true to start with the window menu open (a menu must be on)
 *   data               for a game built with its data separate (--data=separate): where its data
 *                      file is (beside the script or module, or beside the page), or its bytes
 *                      already in hand as an ArrayBuffer or Uint8Array
 *   onMessage(kind, text)   what the game would say: "controller" (which are connected),
 *                      "keyboard" (to click the game, or null once it has the keyboard) and
 *                      "stopped" (why a game that went wrong stopped)
 *
 * and createGame gives back the game to steer: start, pause, resume, stop, press and release a
 * button by name (a press counts for the next frame even if it is released before then, as a
 * tapped key does), readSave and writeSave, readState (every variable and list, by name),
 * setPauseWhenUnfocused, toggleFullscreen, canFillScreen,
 * paused, title,
 * finished — a promise that settles with { wentWrong, message } when the game stops — and ready,
 * which settles once the game has what it needs to play its first frame (its data file).
 */

const PAGE_FRAME_MS = 1000 * RG_CONSOLE_TICKS_A_FRAME / RG_CONSOLE_TICKS_A_SECOND; /* the console's frame, by its clock */

/* The console's buttons by name, in the order rg_players_read takes them, a bit each. */
const PAGE_BUTTONS = ["a", "b", "select", "start", "right", "left", "up", "down", "r", "l"];

/* The window's keys: the arrows, X for A, Z for B, Enter for Start, Backspace or right Shift for
 * Select, A for L and S for R. */
const PAGE_KEYS = { KeyX: "a", KeyZ: "b", Backspace: "select", ShiftRight: "select", Enter: "start",
  ArrowRight: "right", ArrowLeft: "left", ArrowUp: "up", ArrowDown: "down", KeyS: "r", KeyA: "l" };

/* A controller's buttons, by the numbers the browser's "standard" layout gives them (the layout
 * nearly every controller is reported in), to the console's: the bottom face button is A and the
 * right one B, as an Xbox controller labels them, the shoulder buttons are L and R, and the d-pad
 * is the d-pad. */
const PAGE_PAD_BUTTONS = [[0, "a"], [1, "b"], [8, "select"], [9, "start"], [15, "right"], [14, "left"], [12, "up"],
  [13, "down"], [5, "r"], [4, "l"]];

/* How far the left stick goes, out of 1, before it counts as the d-pad. A stick at rest seldom
 * reads exactly 0, and a worn one rests well off it, so a little way counts as nothing. */
const PAGE_STICK_DEAD_ZONE = 0.5;

const PAGE_NO_CONTROLLER = "To use a controller, connect it and press a button on it.";
const PAGE_CLICK_TO_PLAY = "Click the game to play.";

function page_bit(name) {
  const at = PAGE_BUTTONS.indexOf(name);
  if (at < 0) throw new Error(`There is no button called ${name}. The buttons are ${PAGE_BUTTONS.join(", ")}.`);
  return 1 << at;
}

/* The browser's own storage for this page, or null where it keeps none (a page opened in some
 * browsers' private windows refuses when asked). */
function page_default_storage() {
  try {
    return typeof localStorage === "undefined" ? null : localStorage;
  } catch (error) {
    return null;
  }
}

function page_create(host) {
  if (!host.canvas || !host.canvas.getContext) {
    throw new Error("createGame needs a canvas to draw on: createGame({ canvas: document.querySelector(\"canvas\") }).");
  }
  const canvas = host.canvas;
  const context = canvas.getContext("2d");
  const image = context.createImageData(RG_SCREEN_WIDTH, RG_SCREEN_HEIGHT);
  const say = host.onMessage || (() => {});
  const key_map = host.keyMap || PAGE_KEYS;
  const fullscreen_key = host.fullscreenKey === undefined ? "KeyF" : host.fullscreenKey;
  const storage = host.storage === undefined ? page_default_storage() : host.storage;
  /* The menu, the hotkeys and what a player keeps: a page VBlank wrote asks for them (rg_mount.js).
   * A page of the host's own has keys of its own to think of, so it asks if it wants them. */
  const has_menu = Boolean(host.menu && RG_PAGE_MENU);
  const player = has_menu ? page_settings(storage, () => draw_menu()) : null;
  /* SAVE STATES are kept in the page's storage, a state a key, under the game's title and code: the
   * code is stable when the game is built again, and tells two games of one title apart. A page with no
   * storage keeps none, and its menu has no Save or Load. */
  const state_key = (slot) => `vblank-state:${rg_title()}:${RG_GAME_CODE}:${slot}`;
  let state_asked = null; /* the save or load the player asked for, done at the next frame boundary */
  const states = !has_menu || !storage || !RG_PAGE_MENU.headings.some((heading) => heading.states) ? {} : {
    state(action, slot) { state_asked = { action, slot }; },
    state_text(slot) {
      const kept = read_state(slot);
      return kept === null ? "Empty" : page_time_words(kept.at);
    },
  };
  const menu = has_menu ? page_menu(player, { fullscreen() { toggle_fullscreen(); }, quit() { menu.toggle(); handle.stop(); }, ...states }) : null;
  let paused_by_key = false;
  let fast_held = false;
  if (player) player.read_kept();
  const save_key = host.saveKey || `vblank-save:${rg_title()}`;
  const left_samples = new Int16Array(RG_SOUND_FRAME_MOST);
  const right_samples = new Int16Array(RG_SOUND_FRAME_MOST);
  const page_unfocused = () => typeof document !== "undefined" && document.hasFocus && !document.hasFocus();

  /* Everything the game listens to, so a game that stops can let go of all of it (release_page). */
  const listening = [];
  function listen_to(target, type, listener) {
    target.addEventListener(type, listener);
    listening.push([target, type, listener]);
  }
  function release_page() {
    for (const [target, type, listener] of listening.splice(0)) target.removeEventListener(type, listener);
  }

  let audio = host.audio && host.audio !== true ? host.audio : null;
  let sound_at = 0;
  let keys_down = 0;
  let keys_tapped = 0;
  let pressed_by_caller = 0;
  let tapped_by_caller = 0;
  let pause_when_unfocused = host.pauseWhenUnfocused !== false;
  let paused_by_caller = false;
  let paused_by_focus = false;
  let started = false;
  let stopped = false;
  let finish;
  const finished = new Promise((resolve) => { finish = resolve; });

  rg_active_driver = { dump_variable() {}, dump_list() {}, sound_logged() {} };
  /* A game that reads a file as it starts (a data pack, or a copy to unpack) is handed it here. */
  if (host.startFile) rg_start_file_hand(host.startFile);

  /* --- the save --- */

  function load_save() {
    if (rg_save_size() === 0 || !storage) return;
    try {
      const kept = storage.getItem(save_key);
      if (!kept) return;
      const bytes = Uint8Array.from(atob(kept), (char) => char.charCodeAt(0));
      if (bytes.length === rg_save_size()) rg_save_bytes().set(bytes);
    } catch (error) {
      /* a browser that keeps nothing for this page plays the game from a new cartridge */
    }
  }

  function write_save() {
    if (!storage) return;
    try {
      let text = "";
      for (const byte of rg_save_bytes()) text += String.fromCharCode(byte);
      storage.setItem(save_key, btoa(text));
      rg_save_file_written();
    } catch (error) {
      /* tried again when the save is next due */
    }
  }

  /* --- the picture: fifteen bits a pixel, each channel widened to eight --- */

  /* Every colour the console can show, finished: the five bits of each channel widened to eight by
   * repeating its top bits underneath ((c << 3) | (c >> 2)), so the brightest is 255 and not 248,
   * and an opaque alpha. The canvas's bytes are viewed as one 32-bit number a pixel, and a number
   * written is its four bytes in the order the machine keeps them, which on every machine a
   * browser runs on has the lowest byte first: red is the lowest byte, then green, blue, and alpha
   * the top one. */
  const finished_colors = new Uint32Array(0x8000);
  for (let color = 0; color < finished_colors.length; color++) {
    const red = color & 0x1F, green = (color >> 5) & 0x1F, blue = (color >> 10) & 0x1F;
    finished_colors[color] = (255 << 24 | (((blue << 3) | (blue >> 2)) << 16) | (((green << 3) | (green >> 2)) << 8) |
                              ((red << 3) | (red >> 2))) >>> 0;
  }
  const image_words = new Uint32Array(image.data.buffer);
  const picture_up = new Uint16Array(RG_SCREEN_WIDTH * RG_SCREEN_HEIGHT); /* what the canvas shows */
  let canvas_has_a_picture = false;

  /* A picture that is the one already on the canvas is not put there again. */
  function present() {
    const pixels = rg_screen_shown();
    if (canvas_has_a_picture) {
      let at = 0;
      while (at < pixels.length && pixels[at] === picture_up[at]) at++;
      if (at === pixels.length) return;
    }
    for (let i = 0; i < pixels.length; i++) image_words[i] = finished_colors[pixels[i] & 0x7FFF];
    picture_up.set(pixels);
    canvas_has_a_picture = true;
    context.putImageData(image, 0, 0);
  }

  /* --- the sound --- */

  /* THE SOUND IS PLAYED BY A WORKLET where the browser has one. A worklet is a little program
   * that runs on the browser's audio thread, which keeps going whatever the page is busy with: a
   * frame's sound is handed to it as a message and waits in a ring of samples, so a frame the page
   * is late with is covered by what is already waiting, where a sound scheduled from the page one
   * frame at a time is a gap the moment the page is late. It also makes nothing for the browser to
   * collect: the old way made two objects for every frame, sixty times a second.
   *
   * The worklet runs at the sound device's rate and the game makes sound at RG_SOUND_RATE, so
   * each sample the device is given is read from between two of the game's, which plays the sound
   * at the right pitch on any device: one this page makes, which is asked for the game's own rate and
   * so reads each sample as it is, and one a host handed in at whatever rate it has. A device that
   * ran dry waits for a little sound to be ready before it starts again, and one with more waiting
   * than it should have lets the oldest go, so the sound never falls far behind the game.
   *
   * Its code is written here and loaded from a Blob, since the game is one file. A browser that has
   * no worklets (a page that is not served over https or from localhost is not a secure context),
   * or a page whose content security policy refuses a Blob, plays each frame's sound the old way,
   * as buffers scheduled one after another (play_in_buffers). */
  const SPEAKER_NAME = "vblank-speaker";
  const SPEAKER_CODE = `
    class VBlankSpeaker extends AudioWorkletProcessor {
      constructor(options) {
        super();
        this.rate = options.processorOptions.rate;
        this.step = this.rate / sampleRate; /* the game's samples used up for each one the device is given */
        this.size = Math.ceil(this.rate * 2);
        this.left = new Float32Array(this.size);
        this.right = new Float32Array(this.size);
        this.written = 0; /* the game's samples taken in, ever */
        this.read = 0; /* how far through them the device has got: a fraction, the game's samples being read in between */
        this.priming = true; /* waiting for a little sound to be ready before playing */
        this.port.onmessage = (event) => this.take(event.data.left, event.data.right);
      }
      take(left, right) {
        for (let i = 0; i < left.length; i++) {
          this.left[(this.written + i) % this.size] = left[i];
          this.right[(this.written + i) % this.size] = right[i];
        }
        this.written += left.length;
        if (this.written - this.read > this.rate * 0.25) this.read = this.written - this.rate * 0.05;
      }
      process(inputs, outputs) {
        const out = outputs[0];
        const left = out[0], right = out[1] || out[0];
        for (let i = 0; i < left.length; i++) {
          const waiting = this.written - this.read;
          if (this.priming && waiting >= this.rate * 0.05) this.priming = false;
          if (this.priming || waiting < 2) {
            this.priming = true;
            left[i] = 0;
            right[i] = 0;
            continue;
          }
          const first = Math.floor(this.read), share = this.read - first;
          const a = first % this.size, b = (first + 1) % this.size;
          left[i] = this.left[a] + (this.left[b] - this.left[a]) * share;
          right[i] = this.right[a] + (this.right[b] - this.right[a]) * share;
          this.read += this.step;
        }
        return true;
      }
    }
    registerProcessor(${JSON.stringify(SPEAKER_NAME)}, VBlankSpeaker);
  `;

  let speaker = null; /* the worklet's node, once it is playing */
  let speaker_loading = false;
  let speaker_cannot_load = false;

  /* Starts loading the worklet for the sound device, once. Until it is ready a frame's sound is made
   * and dropped, which still moves every voice on; if it cannot load, the old way takes over. */
  function load_speaker() {
    if (!audio || speaker || speaker_loading || speaker_cannot_load) return;
    if (!audio.audioWorklet || typeof AudioWorkletNode === "undefined" || typeof Blob === "undefined" ||
        typeof URL === "undefined" || typeof URL.createObjectURL !== "function") {
      speaker_cannot_load = true;
      return;
    }
    let address;
    try {
      address = URL.createObjectURL(new Blob([SPEAKER_CODE], { type: "text/javascript" }));
    } catch (error) {
      speaker_cannot_load = true;
      return;
    }
    speaker_loading = true;
    audio.audioWorklet.addModule(address).then(() => {
      const node = new AudioWorkletNode(audio, SPEAKER_NAME, {
        numberOfInputs: 0, numberOfOutputs: 1, outputChannelCount: [2], processorOptions: { rate: RG_SOUND_RATE },
      });
      node.connect(audio.destination);
      speaker = node;
    }).catch(() => {
      speaker_cannot_load = true;
    }).finally(() => {
      speaker_loading = false;
      URL.revokeObjectURL(address);
    });
  }

  /* How loud the player has it, out of 1, by rg_window_gain's rule: the square of the volume, since
   * an ear hears a sound's power. */
  function sound_gain() {
    if (!player) return 1;
    return player.now.muted ? 0 : (player.now.volume * player.now.volume) / 10000;
  }

  /* The frame's sound, sent to play straight after the frame before's. A browser plays nothing
   * until somebody has clicked or pressed a key on the page, so until then it is made and
   * dropped, which still moves every voice on. */
  function play_sound() {
    const count = rg_sound_render_frame(left_samples, right_samples);
    if (!audio || audio.state !== "running" || count === 0) return;
    load_speaker(); /* a device the host handed in is loaded for here, since nothing has been clicked */
    if (speaker) {
      const left = new Float32Array(count), right = new Float32Array(count);
      const gain = sound_gain() / 32768;
      for (let i = 0; i < count; i++) {
        left[i] = left_samples[i] * gain;
        right[i] = right_samples[i] * gain;
      }
      speaker.port.postMessage({ left, right }, [left.buffer, right.buffer]);
    } else if (speaker_cannot_load) {
      play_in_buffers(count);
    }
  }

  /* Each frame's sound a buffer of its own, scheduled to start where the one before ends. */
  function play_in_buffers(count) {
    const buffer = audio.createBuffer(2, count, RG_SOUND_RATE);
    const left = buffer.getChannelData(0), right = buffer.getChannelData(1);
    const gain = sound_gain() / 32768;
    for (let i = 0; i < count; i++) {
      left[i] = left_samples[i] * gain;
      right[i] = right_samples[i] * gain;
    }
    const source = audio.createBufferSource();
    source.buffer = buffer;
    source.connect(audio.destination);
    const now = audio.currentTime;
    if (sound_at < now + 0.02 || sound_at > now + 0.25) sound_at = now + 0.05;
    source.start(sound_at);
    sound_at += count / RG_SOUND_RATE;
  }

  function start_sound() {
    if (host.audio === false) return;
    if (!audio && typeof window !== "undefined") {
      const Context = window.AudioContext || window.webkitAudioContext;
      if (Context) audio = made_at_game_rate(Context);
    }
    load_speaker();
    /* A device a click made while the game is paused waits with the game. */
    match_sound();
  }

  /* A sound device at the game's own rate, so that nothing has to be read in between: asked for, and
   * the browser's own where it will not give one. */
  function made_at_game_rate(Context) {
    try {
      return new Context({ sampleRate: RG_SOUND_RATE });
    } catch (error) {
      return new Context();
    }
  }

  function tab_hidden() { return typeof document !== "undefined" && document.hidden; }

  /* The sound waits while the game does: paused, or in a tab behind another. */
  function match_sound() {
    if (!audio) return;
    if ((is_paused() || tab_hidden()) && audio.state === "running") audio.suspend();
    else if (!is_paused() && !tab_hidden() && audio.state === "suspended") audio.resume();
  }

  /* --- pausing --- */

  function is_paused() { return paused_by_caller || paused_by_focus || paused_by_key || Boolean(menu && menu.open); }

  /* What is over the game, as the player's settings set it now. */
  function draw_menu() {
    if (!menu) return;
    const status = [];
    if (player.now.frame_rate) status.push(`${Math.round(frames_a_second)} fps`);
    if (is_paused()) status.push("PAUSED");
    else if (fast_held) status.push(`FAST FORWARD ${player.now.fast_forward_speed}x`);
    page_menu_draw(canvas, menu, status);
  }

  /* The menu opened or closed, or a key pressed in it: the game holds while it is open, and goes on
   * as it stood when it closes. */
  function after_menu() {
    match_sound();
    draw_menu();
    wake();
  }

  /* A key the page has kept for itself down: what it does is the player's hotkeys'. */
  function hotkey_pressed(name, repeat) {
    if (name === "menu") {
      if (!repeat) menu.toggle();
    } else if (name === "fast_forward") {
      fast_held = true;
    } else if (menu.open) {
      if (name !== "pause" && name !== "step" && !repeat) switch_hotkey(name);
    } else if (name === "pause") {
      if (!repeat) paused_by_key = !paused_by_key;
    } else if (name === "step") {
      if (paused_by_key) play_frame(true);
    } else if (!repeat) {
      switch_hotkey(name);
    }
    after_menu();
  }

  function switch_hotkey(name) {
    if (name === "fullscreen") return toggle_fullscreen();
    const setting = name === "mute" ? "muted" : "frame_rate";
    player.now[setting] = !player.now[setting];
    return player.write_kept();
  }

  /* A key down, for a page with the menu: gives whether the page took it, so the game does not. */
  function menu_key_down(event) {
    if (player.capturing) {
      if (!event.repeat) player.capture_key(event.code);
      after_menu();
      return true;
    }
    const button = player.button_of_key(event.code);
    const hotkey = player.hotkey_of_key(event.code);
    if (PAGE_MENU_OPEN_KEYS.includes(event.code) && button === undefined && hotkey === undefined) {
      hotkey_pressed("menu", event.repeat);
      return true;
    }
    if (states.state && PAGE_STATE_KEYS[event.code] && button === undefined && hotkey === undefined) {
      if (!event.repeat) {
        states.state(PAGE_STATE_KEYS[event.code], 0);
        /* Paused, a frame plays as a step does, so the request is done at the boundary at once. */
        if (paused_by_key && !menu.open) play_frame(true);
      }
      return true;
    }
    if (menu.open && PAGE_MENU_MOVES[event.code]) {
      if (!(event.repeat && event.code === "Enter")) menu.press(PAGE_MENU_MOVES[event.code]);
      after_menu();
      return true;
    }
    if (hotkey === undefined) return false;
    hotkey_pressed(hotkey, event.repeat);
    return true;
  }

  /* The controller's buttons that work the menu, read as it stands since a browser keeps no events
   * for them. Back and Start together, or the guide button, open it; the d-pad moves, the bottom
   * face button chooses, as it presses A here, and the right one closes. */
  const PAGE_PAD_MOVES = { 12: "up", 13: "down", 14: "left", 15: "right", 0: "enter", 1: "close" };
  let pad_was_down = new Set();

  function read_menu_pad() {
    if (!menu || host.gamepads === false || typeof navigator === "undefined" || !navigator.getGamepads) return;
    const down = new Set();
    for (const pad of navigator.getGamepads()) {
      if (!pad || !pad.connected) continue;
      pad.buttons.forEach((button, number) => { if (button.pressed) down.add(number); });
    }
    const went_down = [...down].filter((number) => !pad_was_down.has(number));
    pad_was_down = down;
    for (const number of went_down) {
      if (player.capture_pad(number)) return after_menu();
      if (number === 16 || (down.has(8) && down.has(9) && (number === 8 || number === 9))) {
        menu.toggle();
        return after_menu();
      }
      if (menu.open && PAGE_PAD_MOVES[number]) {
        menu.press(PAGE_PAD_MOVES[number]);
        after_menu();
      }
    }
    return undefined;
  }

  function set_focus_pause(paused) {
    paused_by_focus = paused;
    match_sound();
    wake();
  }

  /* --- the buttons --- */

  /* Every console button held on any controller plugged in, the left stick as the d-pad. The
   * browser keeps no events for these: a controller is read as it stands, once a frame. */
  function pad_buttons() {
    if (host.gamepads === false || typeof navigator === "undefined" || !navigator.getGamepads) return 0;
    let held = 0;
    for (const pad of navigator.getGamepads()) {
      if (!pad || !pad.connected) continue;
      const buttons = player ? PAGE_BUTTONS.map((name) => [player.now.pads[name], name]) : PAGE_PAD_BUTTONS;
      for (const [from, to] of buttons) if (pad.buttons[from] && pad.buttons[from].pressed) held |= page_bit(to);
      const [x = 0, y = 0] = pad.axes;
      if (x > PAGE_STICK_DEAD_ZONE) held |= page_bit("right");
      if (x < -PAGE_STICK_DEAD_ZONE) held |= page_bit("left");
      if (y < -PAGE_STICK_DEAD_ZONE) held |= page_bit("up");
      if (y > PAGE_STICK_DEAD_ZONE) held |= page_bit("down");
    }
    return held;
  }

  function say_controllers() {
    if (host.gamepads === false || typeof navigator === "undefined") return;
    const pads = navigator.getGamepads ? Array.from(navigator.getGamepads()).filter((pad) => pad && pad.connected) : [];
    say("controller", pads.length === 0 ? PAGE_NO_CONTROLLER : `Controller: ${pads.map((pad) => pad.id).join(", ")}.`);
  }

  /* A key that went down and came up again between two frames still counts for the next one. The
   * keyboard, the controllers and the caller's presses are one gamepad: a button held on any of
   * them is held.
   *
   * Every one of them is the FIRST player's: the page seats one player, however many controllers
   * are plugged in, so a game for more plays here with the others never connected. Giving each
   * controller a player of its own is not done yet; the runtime reads up to RG_MOST_PLAYERS, so it
   * is only this function that changes. */
  function read_buttons() {
    rg_players_read([keys_down | keys_tapped | pressed_by_caller | tapped_by_caller | pad_buttons()]);
    tapped_by_caller = 0;
    keys_tapped = 0;
  }

  /* --- the screen --- */

  /* The canvas fills the screen, unless the host names something holding it. A browser keeps the
   * shape of a canvas that fills the screen, with black either side, and the page's
   * `image-rendering` keeps every pixel square however big. Safari before 16.4 names these with
   * "webkit". */
  const filling = host.fullscreenElement || canvas;
  const can_fill_screen = Boolean(filling.requestFullscreen || filling.webkitRequestFullscreen);

  function toggle_fullscreen() {
    let asked;
    if (document.fullscreenElement || document.webkitFullscreenElement) {
      asked = (document.exitFullscreen || document.webkitExitFullscreen).call(document);
    } else if (can_fill_screen) {
      asked = (filling.requestFullscreen || filling.webkitRequestFullscreen).call(filling);
    }
    /* A browser that refuses (a page in a frame not allowed to) leaves the page as it was. */
    if (asked && asked.catch) asked.catch(() => {});
  }

  /* --- listening to the browser --- */

  function listen() {
    if (typeof window === "undefined") return;
    if (host.keys !== false) {
      const target = host.keyTarget || window;
      listen_to(target,"keydown", (event) => {
        start_sound();
        /* With Cmd, Ctrl or Alt it is the browser's shortcut (Cmd+A, Ctrl+S, Alt+Left), not a button. */
        if (event.metaKey || event.ctrlKey || event.altKey) return;
        if (player) {
          if (menu_key_down(event)) {
            event.preventDefault();
            return;
          }
        } else if (fullscreen_key && event.code === fullscreen_key) {
          if (!event.repeat) toggle_fullscreen();
          event.preventDefault();
          return;
        }
        const button = player ? player.button_of_key(event.code) : key_map[event.code];
        if (button === undefined) return;
        keys_down |= page_bit(button);
        keys_tapped |= page_bit(button);
        event.preventDefault();
      });
      listen_to(target,"keyup", (event) => {
        if (player && player.hotkey_of_key(event.code) === "fast_forward") {
          fast_held = false;
          draw_menu();
        }
        const button = player ? player.button_of_key(event.code) : key_map[event.code];
        if (button === undefined) return;
        keys_down &= ~page_bit(button);
        event.preventDefault();
      });
    }
    listen_to(window,"pointerdown", start_sound);
    /* A key let go while the page has not got the keyboard never reaches it, and would be held
     * for ever: so whenever the page loses it, every key is let go — and, unless the host asks
     * not to, the game pauses, so a player who looks away does not come back to a game that went on
     * without them. */
    listen_to(window,"blur", () => {
      keys_down = 0;
      if (pause_when_unfocused) set_focus_pause(true);
    });
    listen_to(window,"focus", () => {
      set_focus_pause(false);
      say("keyboard", null);
    });
    /* A tab behind another gets no frames, so the game stops where it is; its sound waits with
     * it, rather than playing out what was queued. */
    listen_to(document, "visibilitychange", () => {
      if (tab_hidden()) keys_down = 0;
      match_sound();
    });
    if (host.gamepads !== false) {
      listen_to(window,"gamepadconnected", say_controllers);
      listen_to(window,"gamepaddisconnected", say_controllers);
    }
  }

  /* --- the data file, for a game built with its data separate --- */

  /* A game built with its big tables in a file of their own (JS::Printer#data_file) has them
   * filled in from it (rg_data_fill) before its first frame. It is fetched from beside the script
   * unless the host names where it is, or hands its bytes over. A file that is not there, or that
   * another build of the game wrote, stops the game before it starts. */
  const needs_data = typeof rg_data_fill === "function";

  async function load_data() {
    const source = host.data != null ? host.data : (typeof rg_data_beside === "undefined" ? null : rg_data_beside);
    let bytes;
    if (source instanceof ArrayBuffer) {
      bytes = new Uint8Array(source);
    } else if (ArrayBuffer.isView(source)) {
      bytes = new Uint8Array(source.buffer, source.byteOffset, source.byteLength);
    } else if (typeof source === "string" || (typeof URL !== "undefined" && source instanceof URL)) {
      let response;
      try {
        response = await fetch(source);
      } catch (error) {
        response = { ok: false, statusText: error.message };
      }
      if (!response.ok) {
        throw new Error(`it cannot load its data file ${source} (${response.status || response.statusText}). ` +
                        "Put the data file beside the game, or give its address to createGame as data.");
      }
      bytes = new Uint8Array(await response.arrayBuffer());
    } else {
      throw new Error("it cannot read the data that createGame was given. Give the data file's address, " +
                      "or its bytes as an ArrayBuffer or a Uint8Array.");
    }
    const stamp = Array.from(bytes.subarray(0, RG_DATA_STAMP.length / 2), (byte) => byte.toString(16).padStart(2, "0")).join("");
    if (stamp !== RG_DATA_STAMP) {
      const named = typeof source === "string" ? `${source} ` : "";
      throw new Error(`its data file ${named}is from a different build of the game. Build the game again, ` +
                      "and put the new data file beside it.");
    }
    rg_data_fill(bytes);
  }

  const ready = needs_data ? load_data() : Promise.resolve();
  ready.catch(() => {}); /* said by start, when the game is started */

  /* --- save states --- */

  /* What the page keeps for +slot+ (0 is the quick one): { at, text }, or null for a slot that holds none. */
  function read_state(slot) {
    try {
      const kept = JSON.parse(storage.getItem(state_key(slot)));
      return kept && typeof kept.text === "string" ? kept : null;
    } catch (error) {
      return null;
    }
  }

  /* Tells the player how a save or load went, in the menu's notice and to the host. */
  function show_state_result(format, slot) {
    const words = format.replace("%s", slot === 0 ? "the quick slot" : `slot ${slot}`);
    player.say(words);
    say("state", words);
    draw_menu();
  }

  /* The save or load the player asked for, done as the game's frame ends, before its sound is made: the one
   * moment every routine is stopped at its wait, so a state written now is the game whole and one read back
   * puts the game where it was (the windowless run does the same, in rg_headless.js). A state another build
   * saved is shown in plain words and the game plays on. */
  function serve_state_request() {
    if (state_asked === null) return;
    const { action, slot } = state_asked;
    state_asked = null;
    if (action === "save") {
      try {
        storage.setItem(state_key(slot), JSON.stringify({ at: Date.now(), text: rg_state_write() }));
        show_state_result("Saved to %s", slot);
      } catch (error) {
        if (error instanceof RgStopped) throw error;
        player.say("The state cannot be kept. The page's storage is full or cannot be written to.");
        draw_menu();
      }
      return;
    }
    const kept = read_state(slot);
    if (kept === null) return show_state_result("There is no state in %s", slot);
    const problem = rg_state_header_problem(kept.text);
    if (problem !== null) {
      player.say(problem);
      draw_menu();
      return;
    }
    rg_state_read(kept.text);
    show_state_result("Loaded %s", slot);
  }

  /* --- the frames --- */

  let due = 0;

  /* The browser's own clock, in its local time, handed to the cartridge's (rg_clock_reads) as each
   * frame of the game starts, the first among them. A clock keeps real time, so a page paused or
   * left in the background finds the time gone by on the first frame it plays after. */
  function read_browser_clock() {
    const now = new Date();
    rg_clock_reads(now.getFullYear(), now.getMonth() + 1, now.getDate(), now.getHours(), now.getMinutes(), now.getSeconds());
  }

  /* However the game stops, it lets go of the page — its keys go back to the page, F and the
   * window's focus are no longer its business — and its sound stops with it, and no frame is
   * left asked for. */
  function stop_with(went_wrong, message) {
    stopped = true;
    release_page();
    if (frame_request !== null && typeof window.cancelAnimationFrame === "function") window.cancelAnimationFrame(frame_request);
    frame_request = null;
    if (audio && audio.state === "running") audio.suspend();
    finish({ wentWrong: went_wrong, message });
  }

  /* One frame of the game: it plays until it waits for the screen, and that frame's boundary
   * follows. +draw+ marks whether its picture is put on the canvas: a page that is behind plays every
   * frame it owes, and only the last of them is ever seen, so the others are not drawn. A game
   * that stops leaves its last picture up, however many frames were owed. The sound and the save
   * are the frame's own work and are done for every frame, drawn or not. */
  function play_frame(draw) {
    try {
      read_browser_clock();
      if (!rg_game_main()) {
        present();
        stop_with(false, "the game ended");
        return;
      }
      serve_state_request();
      play_sound();
      rg_frame_begins();
      if (draw) present();
      if (rg_save_file_is_due()) write_save();
      read_buttons();
    } catch (error) {
      if (!(error instanceof RgStopped)) {
        stop_with(true, String(error));
        throw error;
      }
      present();
      if (rg_save_unwritten()) write_save();
      if (error.went_wrong) say("stopped", `The game stopped: ${error.message}`);
      stop_with(error.went_wrong, error.message);
    }
  }

  /* The browser is asked for one frame at a time, and not at all while the game is paused: a page
   * that asks for a frame sixty times a second keeps the computer awake for nothing. Whatever ends
   * a pause (wake) asks again. */
  let running = false;
  let frame_request = null;

  function ask_for_a_frame() {
    if (stopped || !running || frame_request !== null) return;
    frame_request = window.requestAnimationFrame(host.uncapped ? tick_uncapped : tick);
  }

  /* The pause is over, or about to be looked at again: the game goes on from where it stood. */
  function wake() {
    if (!running || stopped || is_paused() || frame_request !== null) return;
    due = performance.now();
    ask_for_a_frame();
  }

  function tick(now) {
    frame_request = null;
    if (stopped) return;
    read_menu_pad();
    if (is_paused()) {
      due = now + PAGE_FRAME_MS; /* and when the pause ends, the game goes on from where it stood */
      /* A controller has no events, so a menu open is the one pause that goes on looking at it. */
      if (menu && menu.open) ask_for_a_frame();
      return;
    }
    if (now - due > 250) due = now; /* a page left in the background does not race to catch up */
    const frame_ms = fast_held ? PAGE_FRAME_MS / player.now.fast_forward_speed : PAGE_FRAME_MS;
    while (!stopped && now >= due) {
      due += frame_ms;
      play_frame(now < due);
    }
    measure_frame_rate(now);
    ask_for_a_frame();
  }

  /* A game played as fast as the page can go (host.uncapped): the frames of a part of a second
   * are played with no picture but the last, and the browser is given the page back in between. */
  const UNCAPPED_BATCH_MS = 12;
  const UNCAPPED_BATCH_FRAMES = 20000;

  function tick_uncapped() {
    frame_request = null;
    if (stopped) return;
    const batch_ends = performance.now() + UNCAPPED_BATCH_MS;
    let played = 0;
    do {
      play_frame(false);
      played += 1;
    } while (!stopped && performance.now() < batch_ends && played < UNCAPPED_BATCH_FRAMES);
    if (!stopped) present();
    ask_for_a_frame();
  }

  /* The pictures shown in the last second, for a player who asked to see the rate. */
  let frames_a_second = 0;
  let frames_counted = 0;
  let counted_from = 0;

  function measure_frame_rate(now) {
    frames_counted += 1;
    if (now - counted_from < 1000) return;
    if (counted_from) frames_a_second = (frames_counted * 1000) / (now - counted_from);
    frames_counted = 0;
    counted_from = now;
    if (player && player.now.frame_rate) draw_menu();
  }

  function start() {
    if (started) return;
    started = true;
    listen();
    say_controllers();
    /* A page in a frame on another site starts without the keyboard: a key pressed then goes to
     * the page around it, so it says to click the game, and pauses until it has the keyboard. */
    if (page_unfocused()) {
      say("keyboard", PAGE_CLICK_TO_PLAY);
      if (pause_when_unfocused) set_focus_pause(true);
    }
    if (!needs_data) {
      play_from_first_frame();
      return;
    }
    ready.then(play_from_first_frame, (error) => {
      say("stopped", `The game stopped: ${error.message}`);
      stop_with(true, error.message);
    });
  }

  /* Once the game has its data: the save read in, and the first frame asked for. */
  function play_from_first_frame() {
    if (stopped) return;
    load_save();
    due = performance.now();
    running = true;
    ask_for_a_frame();
  }

  const handle = {
    /* What the menu shows now, for a host and for a test: null on a game with none. */
    get menu() { return menu ? menu.shown : null; },
    title: rg_title(),
    finished,
    ready,
    canFillScreen: can_fill_screen,
    get paused() { return is_paused(); },
    start,
    pause() { paused_by_caller = true; match_sound(); },
    resume() { paused_by_caller = false; match_sound(); wake(); },
    stop() {
      if (stopped) return;
      if (rg_save_unwritten()) write_save();
      stop_with(false, "stopped by the page");
    },
    /* Where every variable and list of the game stands, by the names the game gave them: for a
     * page that plays a program only for what it works out (the shell's menu and unpacking).
     * A list is its items in order, as the game sees them. */
    readState() {
      const vars = {}, lists = {};
      const before = rg_active_driver;
      rg_active_driver = {
        dump_variable(name, value) { vars[name] = value; },
        dump_list(list) {
          lists[list.name] = Array.from({ length: list.length }, (_, i) => list.items[(list.front + i) % list.capacity]);
        },
        sound_logged() {},
      };
      try {
        rg_game_dump_state();
      } finally {
        rg_active_driver = before;
      }
      return { vars, lists };
    },
    /* The save memory as it stands, a copy, for a page to keep (an "export my save" button). */
    readSave() { return Uint8Array.from(rg_save_bytes()); },
    /* Puts +bytes+ in the save memory (an "import a save" button), and keeps them where the host
     * keeps saves. They must be exactly the save memory's size. */
    writeSave(bytes) {
      if (!bytes || bytes.length !== rg_save_size()) {
        throw new Error(`A save for this game must be ${rg_save_size()} bytes, and this one is ${bytes ? bytes.length : 0}.`);
      }
      rg_save_bytes().set(bytes);
      write_save();
    },
    /* A press let go before the next frame still counts for it, as a key's does: a quick tap on
     * an on-screen pad is over in less than a frame. */
    press(name) {
      pressed_by_caller |= page_bit(name);
      tapped_by_caller |= page_bit(name);
    },
    release(name) { pressed_by_caller &= ~page_bit(name); },
    setPauseWhenUnfocused(on) {
      pause_when_unfocused = on;
      set_focus_pause(on && page_unfocused());
    },
    toggleFullscreen: toggle_fullscreen,
  };
  if (menu && host.menuOpen) menu.toggle();
  if (host.autostart !== false) start();
  return handle;
}
