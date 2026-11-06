/*
 * A PORT BUILT AS A SHELL, PLAYED IN A PAGE (Original::Shell says what a shell is; Live::Shell is
 * the Ruby runtime's flow, which this is written again from). The page holds none of the
 * original's data. It plays three kinds of program, each a createGame function of its own (JS#build_shell_page):
 * the game, handed its data pack as it starts; the menu; and one unpacking for each release of the
 * original the game reads, handed the player's copy.
 *
 * The flow: the pack kept in the browser's storage (IndexedDB, since a pack can be megabytes and
 * localStorage holds a few) is checked, and if this shell reads it the game plays. Otherwise the
 * menu plays until the player picks a line. LOAD ROM opens the browser's file picker; the file
 * must be a release the game reads (its size, then its SHA-1), and its unpacking plays handed the
 * file, as fast as the page can go, drawing its progress bar. The bytes it made, after the header
 * for the file's SHA-1, are the pack: kept in storage and handed to the game.
 *
 * Outside every createGame, so it is not part of any game. rg_shell_game gives back a function
 * that is used as createGame is (rg_mount_page takes it), and +host+ may hold two more things for a
 * page of its own or a test:
 *
 *   packStore   { get() -> Promise of the kept pack's bytes or null, put(bytes) -> Promise }
 *   pickFile    () -> Promise of { name, bytes } for the file picked, or null for none
 *
 * and onMessage("refused", words) says why a file or a kept pack was refused (null once it passes).
 */

class RgShellRefused extends Error {}

/* The SHA-1 of +bytes+ (a Uint8Array) as 40 lowercase hex digits (FIPS 180-4). Written out here
 * since a page that is not a secure context has no crypto.subtle. */
function rg_shell_sha1(bytes) {
  const rotate = (value, bits) => ((value << bits) | (value >>> (32 - bits))) >>> 0;
  const padded_length = (((bytes.length + 8) >> 6) + 1) << 6;
  const padded = new Uint8Array(padded_length);
  padded.set(bytes);
  padded[bytes.length] = 0x80;
  const view = new DataView(padded.buffer);
  view.setUint32(padded_length - 8, Math.floor(bytes.length / 0x20000000), false);
  view.setUint32(padded_length - 4, (bytes.length << 3) >>> 0, false);
  const sum = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0];
  const words = new Uint32Array(80);
  for (let block = 0; block < padded_length; block += 64) {
    for (let i = 0; i < 16; i++) words[i] = view.getUint32(block + i * 4, false);
    for (let i = 16; i < 80; i++) words[i] = rotate(words[i - 3] ^ words[i - 8] ^ words[i - 14] ^ words[i - 16], 1);
    let [a, b, c, d, e] = sum;
    for (let i = 0; i < 80; i++) {
      let mixed, constant;
      if (i < 20) { mixed = (b & c) | (~b & d); constant = 0x5A827999; }
      else if (i < 40) { mixed = b ^ c ^ d; constant = 0x6ED9EBA1; }
      else if (i < 60) { mixed = (b & c) | (b & d) | (c & d); constant = 0x8F1BBCDC; }
      else { mixed = b ^ c ^ d; constant = 0xCA62C1D6; }
      const next = (rotate(a, 5) + (mixed >>> 0) + e + constant + words[i]) >>> 0;
      e = d; d = c; c = rotate(b, 30); b = a; a = next;
    }
    sum[0] = (sum[0] + a) >>> 0; sum[1] = (sum[1] + b) >>> 0; sum[2] = (sum[2] + c) >>> 0;
    sum[3] = (sum[3] + d) >>> 0; sum[4] = (sum[4] + e) >>> 0;
  }
  return sum.map((word) => word.toString(16).padStart(8, "0")).join("");
}

function rg_shell_base64_bytes(text) { return Uint8Array.from(atob(text), (char) => char.charCodeAt(0)); }

/* The same words as Original::Releases#size_refusal and #digest_refusal, or null. */
function rg_shell_size_refusal(facts, named, size) {
  const list = facts.releases.list;
  const sizes = list.map((release) => release.size);
  if (sizes.includes(null) || sizes.includes(size)) return null;
  const title = facts.releases.title;
  const readable_sizes = [...new Set(list.filter((release) => release.read).map((release) => release.size))];
  return `${named} is ${size} bytes. A copy of ${title} is ${readable_sizes.join(" or ")} bytes. Name a complete copy of ${title}.`;
}

function rg_shell_digest_refusal(facts, named, sha1) {
  const title = facts.releases.title;
  const readable = facts.releases.list.filter((release) => release.read);
  const known = facts.releases.list.find((release) => release.sha1 === sha1);
  const words = readable.map((release) => `${release.name} (SHA-1 ${release.sha1})`).join(", ");
  if (known && known.read) return null;
  if (known) {
    return `${named} is the ${known.name} release of ${title}. This game does not read that release. It reads ${words}. ` +
      "Name a copy of one of these.";
  }
  return `${named} is not a release of ${title} that this game knows. Its SHA-1 is ${sha1}. A changed or damaged copy has a ` +
    `different SHA-1. This game reads ${words}. Name a copy of one of these.`;
}

/* The same words as IR::StartFile#refusal for a kept pack, or null when this shell reads it. */
function rg_shell_pack_refusal(facts, bytes) {
  const called = facts.called;
  if (bytes.length !== facts.size) {
    return `The ${called} handed to the game is ${bytes.length} bytes. This build reads a ${called} of ${facts.size} bytes. ` +
      `Hand it the ${called} this build was made for.`;
  }
  for (const check of facts.checks) {
    const expected = rg_shell_base64_bytes(check.bytes);
    for (let i = 0; i < expected.length; i++) {
      if (bytes[check.at + i] !== expected[i]) {
        return `This file is not the ${called} this build reads: bytes ${check.at} to ${check.at + expected.length - 1} ` +
          `are not what it holds there. Hand it the ${called} this build was made for.`;
      }
    }
  }
  return null;
}

/* WHERE THE PACK IS KEPT: IndexedDB, in a database named for the shell's folder. */
function rg_shell_store(folder) {
  const name = `vblank-pack:${folder}`;
  const open = () => new Promise((resolve, reject) => {
    const request = indexedDB.open(name, 1);
    request.onupgradeneeded = () => request.result.createObjectStore("packs");
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
  const ask = (mode, action) => open().then((database) => new Promise((resolve, reject) => {
    const request = action(database.transaction("packs", mode).objectStore("packs"));
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  }));
  return {
    async get() {
      const kept = await ask("readonly", (store) => store.get("data.pack"));
      return kept ? new Uint8Array(kept) : null;
    },
    put(bytes) { return ask("readwrite", (store) => store.put(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.length), "data.pack")); },
  };
}

/* THE BROWSER'S FILE PICKER: a file input made and clicked. A browser lets a page open it only
 * soon after a key or a click of the player's. */
function rg_shell_pick_copy() {
  return new Promise((resolve) => {
    const input = document.createElement("input");
    input.type = "file";
    input.addEventListener("change", async () => {
      const file = input.files && input.files[0];
      resolve(file ? { name: file.name, bytes: new Uint8Array(await file.arrayBuffer()) } : null);
    });
    input.addEventListener("cancel", () => resolve(null));
    input.click();
  });
}

/* The shell as a createGame: +facts+ is what Original::Shell holds, as data, and +programs+ the
 * createGame of the game, of the menu and of each unpacking by the release's name. */
function rg_shell_game(facts, programs) {
  return function rg_shell_create(host) {
    host = host || {};
    const store = host.packStore || rg_shell_store(facts.folder);
    const pick = host.pickFile || rg_shell_pick_copy;
    const say = host.onMessage || (() => {});
    const filling = host.fullscreenElement || host.canvas;
    let current = null;
    let begun = false;
    let stopped = false;
    let paused = false;
    let pause_when_unfocused = host.pauseWhenUnfocused !== false;
    let finish;
    const finished = new Promise((resolve) => { finish = resolve; });

    /* One part, playing now on the page's canvas. */
    function play(createPart, more) {
      current = createPart({ ...host, autostart: true, pauseWhenUnfocused: pause_when_unfocused, ...more });
      if (paused) current.pause();
      return current;
    }

    async function kept_pack() {
      const bytes = await store.get();
      if (!bytes) return null;
      const refusal = rg_shell_pack_refusal(facts, bytes);
      if (!refusal) return bytes;
      say("refused", `${refusal} Load your copy of ${facts.title} again to make it.`);
      return null;
    }

    /* The line the player chose on the menu ("load_rom", "settings"), or null once stopped. */
    async function play_menu(settings_open) {
      const menu = play(programs.menu, { menuOpen: settings_open });
      await menu.finished;
      if (stopped) return null;
      return facts.choices[String(menu.readState().vars[facts.menuChoice])] || null;
    }

    /* The pack made from a copy, unpacked in the page: RgShellRefused in the words for a wrong one. */
    async function pack_from_copy(named, bytes) {
      let refusal = rg_shell_size_refusal(facts, named, bytes.length);
      if (refusal) throw new RgShellRefused(refusal);
      const sha1 = rg_shell_sha1(bytes);
      refusal = rg_shell_digest_refusal(facts, named, sha1);
      if (refusal) throw new RgShellRefused(refusal);

      const release = facts.releases.list.find((each) => each.sha1 === sha1);
      const unpacking = play(programs.unpackings[release.name], { startFile: bytes, uncapped: true, menu: false });
      const result = await unpacking.finished;
      if (stopped) return null;
      const state = unpacking.readState();
      const fault = state.vars[facts.names.faultKind];
      if (result.wentWrong || state.vars[facts.names.finished] !== 1 || fault !== 0) {
        throw new RgShellRefused(`${named} is a copy this game reads, and its unpacking stopped part way (fault ${fault}). ` +
                                 "This is a fault in the game. Tell its makers.");
      }
      const made = Uint8Array.from(state.lists[facts.names.bytes], (item) => item & 0xFF);
      const before = rg_shell_base64_bytes(facts.before), after = rg_shell_base64_bytes(facts.after);
      const sha1_bytes = Uint8Array.from(sha1.match(/../g), (pair) => parseInt(pair, 16));
      const pack = new Uint8Array(before.length + 20 + after.length + made.length);
      pack.set(before, 0);
      pack.set(sha1_bytes, before.length);
      pack.set(after, before.length + 20);
      pack.set(made, before.length + 20 + after.length);
      return pack;
    }

    /* The pack made from the file the player picks and kept, or null for none picked or refused. */
    async function load_copy() {
      const picked = await pick();
      if (!picked) return null;
      say("refused", null);
      try {
        const pack = await pack_from_copy(picked.name, picked.bytes);
        if (pack) await store.put(pack);
        return pack;
      } catch (error) {
        if (!(error instanceof RgShellRefused)) throw error;
        say("refused", error.message);
        return null;
      }
    }

    async function run() {
      let pack = await kept_pack();
      let settings_open = false;
      while (!pack) {
        const choice = await play_menu(settings_open);
        if (stopped) return;
        settings_open = choice === "settings";
        if (choice === "load_rom") pack = await load_copy();
        if (stopped) return;
      }
      finish(await play(programs.game, { startFile: pack }).finished);
    }

    function begin() {
      if (begun) return;
      begun = true;
      run().catch((error) => {
        say("stopped", `The game stopped: ${error.message}`);
        finish({ wentWrong: true, message: String(error) });
      });
    }

    const handle = {
      get menu() { return current ? current.menu : null; },
      title: facts.title,
      finished,
      ready: Promise.resolve(),
      canFillScreen: Boolean(filling && (filling.requestFullscreen || filling.webkitRequestFullscreen)),
      get paused() { return current ? current.paused : false; },
      start: begin,
      pause() { paused = true; if (current) current.pause(); },
      resume() { paused = false; if (current) current.resume(); },
      stop() {
        stopped = true;
        if (current) current.stop();
        finish({ wentWrong: false, message: "stopped by the page" });
      },
      readSave() { return current ? current.readSave() : new Uint8Array(0); },
      writeSave(bytes) { if (current) current.writeSave(bytes); },
      press(name) { if (current) current.press(name); },
      release(name) { if (current) current.release(name); },
      setPauseWhenUnfocused(on) {
        pause_when_unfocused = on;
        if (current) current.setPauseWhenUnfocused(on);
      },
      toggleFullscreen() { if (current) current.toggleFullscreen(); },
    };
    if (host.autostart !== false) begin();
    return handle;
  };
}
