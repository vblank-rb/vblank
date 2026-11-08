/*
 * A PORT BUILT AS A SHELL, PLAYED IN A PAGE (Original::Shell has what a shell is; this is the
 * native runtime's rg_shell.c written again, function for function, and Live::Shell is the Ruby
 * one). The page holds none of the original's data. It plays three kinds of program, each a
 * createGame function of its own (JS#build_shell_page): the game, handed its data pack as it
 * starts; the menu; and one unpacking for each release of the original the game reads, handed the
 * player's copy. +facts+ are Original::ShellFacts as data, every sentence a file is refused in
 * among them (rg_refusal.js fills them in).
 *
 * The flow: the pack kept in the browser's storage (IndexedDB, since a pack can be megabytes and
 * localStorage holds a few) is checked, and if it passes the game plays. Otherwise the menu plays
 * until the player picks a line. LOAD ROM opens the browser's file picker, or its folder picker where a
 * release the game reads is several files; the copy must be a release the game reads (its size, then
 * its SHA-1, or each of a folder's files), and its unpacking plays handed the bytes that
 * were checked, as fast as the page can go, drawing its progress bar. The bytes it made, after the
 * header for the file's SHA-1, are the pack: kept in storage and handed to the game. SETTINGS
 * plays the menu again with the page's menu open.
 *
 * Outside every createGame, so it is not part of any game. rg_shell_game gives back a function
 * that is used as createGame is (rg_mount_page takes it), and +host+ may hold two more things for a
 * page of its own or a test:
 *
 *   packStore   { get() -> Promise of the kept pack's bytes or null, put(bytes) -> Promise }
 *   pickFile    (folder) -> Promise of what was picked, or null for none: { name, bytes } for a file,
 *               or { name, files } for a folder when +folder+ is true (see rg_shell_pick_copy)
 *
 * and onMessage("refused", words) is handed why a file or a kept pack was refused (null once it passes).
 */

class RgShellRefused extends Error {}

/* The SHA-1 of +bytes+ (a Uint8Array) as 40 lowercase hex digits (FIPS 180-4), as rg_console_bios.h's
 * rg_sha1_hex. Written out here since a page that is not a secure context has no crypto.subtle. */
function rg_sha1_hex(bytes) {
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

/* Why a file called +named+ of +size+ bytes is no release this game could read, or null: Original::Releases#size_refusal. */
function rg_shell_size_refusal(facts, named, size) {
  const sizes = facts.releases.map((release) => release.size);
  if (sizes.includes(null) || sizes.includes(size)) return null;
  return rg_words_fill(facts.release_words.wrong_size, { named, size });
}

/* Why a copy called +named+ whose SHA-1 is +sha1+ is refused, or null when it is a release the game
 * reads: Original::Releases#digest_refusal. */
function rg_shell_digest_refusal(facts, named, sha1) {
  const known = facts.releases.find((release) => release.sha1 === sha1);
  if (known && known.read) return null;
  if (known) return rg_words_fill(facts.release_words.unread[known.name], { named });
  return rg_words_fill(facts.release_words.unknown, { named, sha1 });
}

/* --- a copy that is a folder, as Original::Releases#match_folder takes one --- */

/* Whether a release the game reads is several files, so LOAD ROM asks for a folder. */
function rg_shell_copy_is_folder(facts) {
  return facts.releases.some((release) => release.read && release.files);
}

/* The name in +names+ that is +file_name+ without regard to case, or null. */
function rg_shell_file_in(names, file_name) {
  const wanted = file_name.toLowerCase();
  return names.find((name) => name.toLowerCase() === wanted) || null;
}

/* The first release the game reads whose every file is among +names+, or null. */
function rg_shell_release_in_folder(facts, names) {
  return facts.releases.find((release) => release.read && release.files &&
    release.files.every((file) => rg_shell_file_in(names, file.name) !== null)) || null;
}

/* Why the folder +named+, holding +names+, is refused when it holds no release whole. */
function rg_shell_lacking_refusal(facts, named, names) {
  const words = facts.release_words;
  if (words.folder) return rg_words_fill(words.folder, { named });
  const lacking = facts.releases.filter((release) => release.read && release.files).map((release) => {
    const missing = release.files.map((file) => file.name).filter((name) => rg_shell_file_in(names, name) === null);
    return rg_words_fill(words.release_lacks, { release: release.name, missing: missing.join(words.missing_join) });
  });
  return rg_words_fill(words.lacking, { named, lacking: lacking.join(words.lacking_join) });
}

/* The pack for a copy whose SHA-1 is +sha1+, holding +made+, what the unpacking wrote. */
function rg_shell_pack_for(facts, sha1, made) {
  const before = facts.pack_before_sha1, after = facts.pack_after_sha1;
  const pack = new Uint8Array(before.length + 20 + after.length + made.length);
  pack.set(before, 0);
  for (let i = 0; i < 20; i++) pack[before.length + i] = parseInt(sha1.substr(2 * i, 2), 16);
  pack.set(after, before.length + 20);
  pack.set(made, before.length + 20 + after.length);
  return pack;
}

/* WHERE THE PACK IS KEPT: IndexedDB, in a database named for the shell's folder, under the pack
 * file's name. */
function rg_shell_store(facts) {
  const name = `vblank-pack:${facts.folder}`;
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
      const kept = await ask("readonly", (store) => store.get(facts.pack_file));
      return kept ? new Uint8Array(kept) : null;
    },
    put(bytes) {
      return ask("readwrite", (store) => store.put(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.length), facts.pack_file));
    },
  };
}

/* THE BROWSER'S FILE PICKER: a file input made and clicked, asking for a folder where a release the
 * game reads is several files. A browser lets a page open it only soon after a key or a click of the
 * player's. A file comes back as { name, bytes }; a folder as { name, files }, each of its own files
 * (not those in a folder inside it) a { name, read } whose read() gives its bytes, so only the files
 * a release names are ever read. */
function rg_shell_pick_copy(folder) {
  return new Promise((resolve) => {
    const input = document.createElement("input");
    input.type = "file";
    if (folder) input.webkitdirectory = true;
    input.addEventListener("change", async () => {
      const picked = Array.from(input.files || []);
      if (picked.length === 0) return resolve(null);
      if (!folder) return resolve({ name: picked[0].name, bytes: new Uint8Array(await picked[0].arrayBuffer()) });
      const own = picked.filter((file) => file.webkitRelativePath.split("/").length === 2);
      resolve({ name: picked[0].webkitRelativePath.split("/")[0],
                files: own.map((file) => ({ name: file.name, read: async () => new Uint8Array(await file.arrayBuffer()) })) });
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
    const store = host.packStore || rg_shell_store(facts);
    const pick = host.pickFile || rg_shell_pick_copy;
    const tell = host.onMessage || (() => {});
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

    /* The kept pack when it passes the check, else null, the player told why when one is there. */
    async function kept_pack() {
      const bytes = await store.get();
      if (!bytes) return null;
      const refusal = rg_start_file_refusal(bytes, facts.pack_rules.numbers, facts.pack_rules.words);
      if (refusal === null) return bytes;
      tell("refused", rg_words_fill(facts.words.kept_pack_refused, { path: facts.pack_file, refusal }));
      return null;
    }

    /* The line the player chose on the menu ("load_rom", "settings"), or null once stopped. */
    async function play_menu(settings_open) {
      const menu = play(programs.menu, { menuOpen: settings_open });
      await menu.finished;
      if (stopped) return null;
      const choice = menu.readState().vars[facts.menu.choice_variable];
      if (choice === facts.menu.load_rom) return "load_rom";
      if (choice === facts.menu.settings) return "settings";
      return null;
    }

    /* The pack made from a copy that is one file, unpacked in the page: RgShellRefused in the words
     * for a wrong one. */
    async function pack_from_copy(named, bytes) {
      if (facts.release_words.one_file) throw new RgShellRefused(rg_words_fill(facts.release_words.one_file, { named }));
      let refusal = rg_shell_size_refusal(facts, named, bytes.length);
      if (refusal) throw new RgShellRefused(refusal);
      const sha1 = rg_sha1_hex(bytes);
      refusal = rg_shell_digest_refusal(facts, named, sha1);
      if (refusal) throw new RgShellRefused(refusal);

      return unpack(named, facts.releases.find((each) => each.sha1 === sha1), bytes);
    }

    /* The same for a copy that is a folder called +named+ holding +files+ ({ name, read }): each file
     * its release names found in any case and checked, and the files joined in the release's order. */
    async function pack_from_folder(named, files) {
      const names = files.map((file) => file.name);
      const release = rg_shell_release_in_folder(facts, names);
      if (!release) throw new RgShellRefused(rg_shell_lacking_refusal(facts, named, names));
      const parts = [];
      for (const wanted of release.files) {
        const spelled = rg_shell_file_in(names, wanted.name);
        const bytes = await files.find((file) => file.name === spelled).read();
        const sha1 = rg_sha1_hex(bytes);
        if (bytes.length !== wanted.size || sha1 !== wanted.sha1) {
          throw new RgShellRefused(rg_words_fill(facts.release_words.wrong_file, {
            named: `${named}/${wanted.name}`, release: release.name, want_size: wanted.size, want_sha1: wanted.sha1,
            size: bytes.length, sha1 }));
        }
        parts.push(bytes);
      }
      const joined = new Uint8Array(parts.reduce((total, part) => total + part.length, 0));
      parts.reduce((at, part) => { joined.set(part, at); return at + part.length; }, 0);
      return unpack(named, release, joined);
    }

    /* The pack the unpacking of +release+ makes from +bytes+, a copy checked already and called
     * +named+; null once stopped. */
    async function unpack(named, release, bytes) {
      const sha1 = release.sha1;
      const unpacking = play(programs.unpackings[release.unpacking], { startFile: bytes, uncapped: true, menu: false });
      const result = await unpacking.finished;
      if (stopped) return null;
      const state = unpacking.readState();
      const fault = state.vars[facts.unpacking.fault_kind];
      if (result.wentWrong || state.vars[facts.unpacking.finished] !== 1 || fault !== 0) {
        throw new RgShellRefused(rg_words_fill(facts.words.unpacking_stopped, { named, fault }));
      }
      return rg_shell_pack_for(facts, sha1, Uint8Array.from(state.lists[facts.unpacking.bytes], (item) => item & 0xFF));
    }

    /* The pack made from the file the player picks and kept, or null for none picked or refused. */
    async function load_copy() {
      const picked = await pick(rg_shell_copy_is_folder(facts));
      if (!picked) return null;
      tell("refused", null);
      try {
        const pack = picked.files ? await pack_from_folder(picked.name, picked.files) : await pack_from_copy(picked.name, picked.bytes);
        if (pack) await store.put(pack);
        return pack;
      } catch (error) {
        if (!(error instanceof RgShellRefused)) throw error;
        tell("refused", error.message);
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
        tell("stopped", `The game stopped: ${error.message}`);
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
