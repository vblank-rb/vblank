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
 * were checked, in a worker of its own (rg_shell_unpack_in_worker), as fast as it can go, drawing
 * its progress bar, which the page shows. The bytes it made, after the
 * header for the file's SHA-1, are the pack: kept in storage and handed to the game. SETTINGS
 * plays the menu again with the page's menu open. Whenever the menu plays again (a picker closed
 * with nothing picked, a file refused, the settings) its cursor is on the line it was left on.
 *
 * THE PICKER NEEDS THE PLAYER'S OWN KEY OR CLICK. A browser opens a file picker only for a short
 * while after one (some seconds), and the menu ends a few frames after the press that chose LOAD
 * ROM, while it shows the line as chosen, so the picker opens inside that time. Nothing slow may
 * be put between the menu's end and the picker.
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

/* AN UNPACKING PLAYS IN A WORKER, AWAY FROM THE PAGE. An unpacking is a game whose routine may work
 * for a long time between two waits for a frame (a port rendering its music before it writes a
 * byte). A page has one thread for everything it does, so played in the page it would stop the page
 * answering for as long as the routine works, and the browser would offer to stop it. A worker is a
 * thread of its own with its own copy of the unpacking and its runtime; it has no window, no
 * document and no canvas, so the two talk only in messages:
 *
 *   to the worker     { bytes, names }: the player's copy and the unpacking's names (facts.unpacking)
 *   to the page       { picture, width, height }: the picture the unpacking has drawn (its progress
 *                     bar), the bytes a canvas takes, each time the unpacking shows one
 *                     { done: { wentWrong, finished, fault, bytes } } once, at its end: the
 *                     unpacking's two numbers and the bytes it made
 *                     { failed }: why the worker could not give its answer
 *
 * rg_shell_unpacking_worker is the worker's side. It is written out as text into the worker's code
 * (rg_shell_unpack_in_worker), so it names nothing but what it is handed and what a worker has. */
function rg_shell_unpacking_worker(createPart) {
  self.onmessage = (start) => {
    const { bytes, names } = start.data;
    /* What the unpacking draws on in place of a canvas: each picture put on it goes to the page. */
    const canvas = {
      getContext: () => ({
        createImageData: (width, height) => ({ width, height, data: new Uint8ClampedArray(width * height * 4) }),
        putImageData(image) {
          const picture = image.data.slice();
          self.postMessage({ picture, width: image.width, height: image.height }, [picture.buffer]);
        },
      }),
    };
    /* A worker has no frames of a screen to wait for, so the unpacking is handed the thread back by
     * a message the worker sends itself. A timer would do, but a browser makes a timer set from a
     * timer wait some milliseconds, and the unpacking would stand idle for them every time. */
    const turn = new MessageChannel();
    let asked = null;
    turn.port1.onmessage = () => {
      const tick = asked;
      asked = null;
      if (tick) tick();
    };
    const frames = { ask(tick) { asked = tick; turn.port2.postMessage(null); return 1; }, cancel() { asked = null; } };
    const part = createPart({ canvas, frames, startFile: bytes, uncapped: true, menu: false, keys: false, gamepads: false,
                              audio: false, storage: null, pauseWhenUnfocused: false });
    part.finished.then((result) => {
      turn.port1.close();
      const state = part.readState({ byteListsPacked: true });
      const made = state.lists[names.bytes] || new Uint8Array(0);
      self.postMessage({ done: { wentWrong: result.wentWrong, finished: state.vars[names.finished],
                                 fault: state.vars[names.fault_kind], bytes: made } }, [made.buffer]);
    }).catch((error) => self.postMessage({ failed: String(error) }));
  };
}

/* The page's side: the unpacking +createPart+ started in a worker of its own on the copy +bytes+,
 * each picture it sends put on +canvas+. Gives back what the shell steers a part by (stop, and the
 * rest doing nothing, since an unpacking has no buttons, no save and no menu), with +finished+ a
 * promise of the worker's done message, or of null once stopped. The worker's code is the
 * unpacking's own text and the function above, at a Blob's address, so a page opened from a disk
 * starts it as a served one does. The copy's bytes are handed over, not copied, where they are a
 * whole buffer of their own.
 *
 * Gives back null where the browser will not start the worker (a page whose content security
 * policy refuses a worker from a Blob, or a browser with no workers): the shell then unpacks in
 * the page, as it did before there was a worker.
 *
 * Must start the code "use strict": the page's own script is strict, and a function's text does not
 * carry that with it. */
function rg_shell_unpack_in_worker(createPart, bytes, names, canvas) {
  if (typeof Worker === "undefined") return null;
  const code = `"use strict";\nconst createPart = ${createPart.toString()};\n(${rg_shell_unpacking_worker.toString()})(createPart);\n`;
  const address = URL.createObjectURL(new Blob([code], { type: "text/javascript" }));
  let worker;
  try {
    worker = new Worker(address);
  } catch (refused) {
    URL.revokeObjectURL(address);
    return null;
  }
  const context = canvas.getContext("2d");
  let image = null;
  let newest = null; /* the newest picture the worker sent that the canvas does not show yet */
  let ended = false;
  let frame_request = null;
  let settle;
  const finished = new Promise((resolve, reject) => { settle = { resolve, reject }; });

  /* The page's own frames go on as the worker works: each shows the newest picture, if one came. */
  function show_newest() {
    if (newest) {
      image = image || context.createImageData(newest.width, newest.height);
      image.data.set(newest.picture);
      context.putImageData(image, 0, 0);
      newest = null;
    }
  }
  function frame() {
    show_newest();
    frame_request = ended ? null : window.requestAnimationFrame(frame);
  }
  const end = () => {
    ended = true;
    worker.terminate();
    URL.revokeObjectURL(address);
    if (frame_request !== null && typeof window.cancelAnimationFrame === "function") window.cancelAnimationFrame(frame_request);
    frame_request = null;
  };
  worker.onmessage = (message) => {
    if (ended) return;
    if (message.data.picture) {
      newest = message.data;
    } else if (message.data.done) {
      show_newest(); /* the unpacking's last picture, the whole bar */
      end();
      settle.resolve(message.data.done);
    } else if (message.data.failed) {
      end();
      settle.reject(new Error(message.data.failed));
    }
  };
  frame_request = window.requestAnimationFrame(frame);
  worker.onerror = (error) => {
    end();
    settle.reject(new Error(error.message || "the unpacking's worker stopped"));
  };
  const whole = bytes.byteOffset === 0 && bytes.byteLength === bytes.buffer.byteLength ? bytes : bytes.slice();
  worker.postMessage({ bytes: whole, names }, [whole.buffer]);
  return {
    menu: null, paused: false, finished,
    stop() { end(); settle.resolve(null); },
    pause() {}, resume() {}, press() {}, release() {}, setPauseWhenUnfocused() {}, toggleFullscreen() {}, writeSave() {},
    readSave: () => new Uint8Array(0),
  };
}

/* AN UNPACKING SPLIT FOR SEVERAL WORKERS (Original::PiecedUnpacking), each a Web Worker on a core
 * of its own. A worker is handed the copy once, then jobs one at a time: a program (the main one,
 * the parts not in pieces, or a part's pieces') and, for a piece, its number, which goes after the
 * copy in the program's start file. It talks to the page in messages:
 *
 *   to the worker     { bytes, names }: the copy and the unpacking's names, once
 *                     { job, program, number }: a job to play; number is null for the main one
 *   to the page       { progress, done }: how many bytes job +progress+ has written, at most once a
 *                     frame's time; { picture, width, height }: the main job's picture
 *                     { ended, finished, fault, wentWrong, bytes }: a job's end, its bytes
 *                     { failed }: why the worker could not give its answer
 *
 * rg_shell_job_worker is the worker's side, written out as text into the worker's code as
 * rg_shell_unpacking_worker is, with the createGame of each program it can be handed. */
function rg_shell_job_worker(createParts) {
  let copy = null;
  let names = null;
  const silent = { getContext: () => ({ createImageData: (width, height) => ({ width, height, data: new Uint8ClampedArray(width * height * 4) }),
                                       putImageData() {} }) };
  const drawing = {
    getContext: () => ({
      createImageData: (width, height) => ({ width, height, data: new Uint8ClampedArray(width * height * 4) }),
      putImageData(image) {
        const picture = image.data.slice();
        self.postMessage({ picture, width: image.width, height: image.height }, [picture.buffer]);
      },
    }),
  };
  function play(job, program, number) {
    let start_file = copy;
    if (number !== null) {
      start_file = new Uint8Array(copy.length + 2);
      start_file.set(copy);
      start_file[copy.length] = number & 0xFF;
      start_file[copy.length + 1] = (number >> 8) & 0xFF;
    }
    const turn = new MessageChannel();
    let asked = null;
    let part = null;
    let sent_at = -Infinity;
    turn.port1.onmessage = () => {
      const tick = asked;
      asked = null;
      if (tick) tick();
    };
    const frames = {
      ask(tick) {
        asked = tick;
        const now = Date.now();
        if (part && now - sent_at >= 100) { /* a few times a second: the read is of every variable */
          sent_at = now;
          self.postMessage({ progress: job, done: part.readState({ lists: false }).vars[names.bytes_done] });
        }
        turn.port2.postMessage(null);
        return 1;
      },
      cancel() { asked = null; },
    };
    part = createParts[program]({ canvas: number === null ? drawing : silent, frames, startFile: start_file, uncapped: true,
                                  menu: false, keys: false, gamepads: false, audio: false, storage: null, pauseWhenUnfocused: false });
    part.finished.then((result) => {
      turn.port1.close();
      const state = part.readState({ byteListsPacked: true });
      const made = state.lists[names.bytes] || new Uint8Array(0);
      self.postMessage({ ended: job, wentWrong: result.wentWrong, finished: state.vars[names.finished],
                         fault: state.vars[names.fault_kind], bytes: made }, [made.buffer]);
    }).catch((error) => self.postMessage({ failed: String(error) }));
  }
  self.onmessage = (message) => {
    const data = message.data;
    if (data.bytes) {
      copy = data.bytes;
      names = data.names;
    } else {
      play(data.job, data.program, data.number);
    }
  };
}

/* How many workers an unpacking in pieces plays on: the page's address may ask
 * (?unpack-workers=N), else the build did (vblank build --unpack-workers N, +given+), else one a
 * processor as the browser counts them, 4 where it does not say; never more than it says. */
function rg_shell_worker_count(given) {
  let asked = given || null;
  if (typeof location !== "undefined" && location.search) {
    const named = Number(new URLSearchParams(location.search).get("unpack-workers"));
    if (Number.isInteger(named) && named > 0) asked = named;
  }
  const most = (typeof navigator !== "undefined" && navigator.hardwareConcurrency) || 4;
  return asked ? Math.min(asked, most) : most;
}

/* The page's side: +plan+ (facts.pieces' entry, ShellFacts::PiecePlan) played on +count+ workers on
 * the copy +bytes+, each job handed out as a worker ends its last, the most work first. Each frame
 * the canvas shows the main job's newest picture with the bar over it, as far as every job's work
 * adds up to, in +bar+'s place and colours (facts.bar). Once every job has ended, the pack is the
 * main job's bytes with each piece's copied over its places, in the order declared. Gives back what
 * rg_shell_unpack_in_worker does, or null where the browser will not start a worker. */
function rg_shell_unpack_on_workers(plan, createParts, bytes, names, bar, count, canvas) {
  if (typeof Worker === "undefined") return null;
  const jobs = [{ program: plan.main, number: null }, ...plan.pieces.map((piece) => ({ program: piece.program, number: piece.number }))];
  const used = [...new Set(jobs.map((job) => job.program))];
  const code = `"use strict";\nconst createParts = {};\n${used.map((program) => `createParts[${program}] = ${createParts[program].toString()};\n`).join("")}` +
               `(${rg_shell_job_worker.toString()})(createParts);\n`;
  const address = URL.createObjectURL(new Blob([code], { type: "text/javascript" }));
  const queue = [0, ...plan.queue.map((piece) => piece + 1)];
  const sizes = [plan.main_bytes, ...plan.pieces.map((piece) => piece.bytes)];
  const works = [plan.main_work, ...plan.pieces.map((piece) => piece.work)];
  const done = jobs.map(() => 0);
  const ended = jobs.map(() => null);
  const workers = [];
  const context = canvas.getContext("2d");
  let image = null;
  let newest = null;
  let stopped = false;
  let frame_request = null;
  let settle;
  const finished = new Promise((resolve, reject) => { settle = { resolve, reject }; });
  const widened = (channel) => (channel << 3) | (channel >> 2);
  const rgba = (color) => [widened(color & 31), widened((color >> 5) & 31), widened((color >> 10) & 31), 255];
  const filled = rgba(bar.filled);
  const empty = rgba(bar.empty);

  function show() {
    if (!newest) return;
    image = image || context.createImageData(newest.width, newest.height);
    image.data.set(newest.picture);
    const across = image.width - (2 * bar.side);
    const top = Math.floor((image.height - bar.height) / 2);
    let shown = 0;
    done.forEach((count_done, job) => {
      if (sizes[job] > 0) shown += (Math.min(Math.max(count_done, 0), sizes[job]) * works[job]) / sizes[job];
    });
    const width = plan.whole_work === 0 ? across : Math.min(across, Math.floor((across * shown) / plan.whole_work));
    for (let row = 0; row < bar.height; row++) {
      for (let x = 0; x < across; x++) {
        image.data.set(x < width ? filled : empty, (((top + row) * image.width) + bar.side + x) * 4);
      }
    }
    context.putImageData(image, 0, 0);
  }
  function frame() {
    show();
    frame_request = stopped ? null : window.requestAnimationFrame(frame);
  }
  function end() {
    stopped = true;
    workers.forEach((worker) => worker.terminate());
    URL.revokeObjectURL(address);
    if (frame_request !== null && typeof window.cancelAnimationFrame === "function") window.cancelAnimationFrame(frame_request);
    frame_request = null;
  }
  function hand_next(worker) {
    const job = queue.shift();
    if (job === undefined) {
      worker.terminate();
      return;
    }
    worker.postMessage({ job, program: jobs[job].program, number: jobs[job].number });
  }
  try {
    for (let n = 0; n < Math.min(count, jobs.length); n++) workers.push(new Worker(address));
  } catch (refused) {
    workers.forEach((worker) => worker.terminate());
    URL.revokeObjectURL(address);
    return null;
  }
  workers.forEach((worker) => {
    worker.onmessage = (message) => {
      if (stopped) return;
      const data = message.data;
      if (data.picture) {
        newest = data;
      } else if (data.progress !== undefined) {
        done[data.progress] = data.done;
      } else if (data.ended !== undefined) {
        ended[data.ended] = data;
        done[data.ended] = sizes[data.ended]; /* an ended job's share is whole, as BackgroundUnpacking's bar is */
        if (ended.every((each) => each !== null)) {
          show();
          end();
          settle.resolve(rg_shell_join_split(plan, ended));
        } else {
          hand_next(worker);
        }
      } else if (data.failed) {
        end();
        settle.reject(new Error(data.failed));
      }
    };
    worker.onerror = (error) => {
      end();
      settle.reject(new Error(error.message || "the unpacking's worker stopped"));
    };
    worker.postMessage({ bytes: bytes.slice(), names });
    hand_next(worker);
  });
  frame_request = window.requestAnimationFrame(frame);
  return {
    menu: null, paused: false, finished,
    stop() { end(); settle.resolve(null); },
    pause() {}, resume() {}, press() {}, release() {}, setPauseWhenUnfocused() {}, toggleFullscreen() {}, writeSave() {},
    readSave: () => new Uint8Array(0),
  };
}

/* What a split's jobs left, taken together (+ended+, one for the main program and then each piece
 * of +plan+, each { wentWrong, finished, fault, bytes }): the main program's bytes with each
 * piece's copied over its places in the order declared, the first fault, main's first. */
function rg_shell_join_split(plan, ended) {
  const pack = new Uint8Array(ended[0].bytes);
  plan.pieces.forEach((piece, index) => {
    const made = ended[index + 1].bytes;
    let from = 0;
    piece.places.forEach(([at, size]) => {
      pack.set(made.subarray(from, from + size), at);
      from += size;
    });
  });
  const fault = ended.map((each) => each.fault).find((kind) => kind !== 0) || 0;
  return { wentWrong: ended.some((each) => each.wentWrong), finished: ended.every((each) => each.finished === 1) ? 1 : 0,
           fault, bytes: pack };
}

/* The file a piece's program is handed as it starts: the copy, +bytes+, then the piece's +number+,
 * two bytes, low byte first (Original::ShellFacts::PlannedPiece#start_file). */
function rg_shell_piece_start_file(bytes, number) {
  const file = new Uint8Array(bytes.length + 2);
  file.set(bytes);
  file[bytes.length] = number & 0xFF;
  file[bytes.length + 1] = (number >> 8) & 0xFF;
  return file;
}

/* The shell as a createGame: +facts+ is what Original::Shell holds, as data, and +programs+ the
 * createGame of the game, of the menu and of each unpacking by the release's name, and of each
 * worker program (+workers+, by the numbers facts.pieces gives them) with +unpackWorkers+, the
 * workers the build asked for (null for one a processor). */
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

    /* The kept pack when it passes the check, else null. A PACK KEPT BY AN OLDER BUILD IS NOT A
     * REFUSAL: it is what a player who opens a new build of the page always has, so the page tells
     * them nothing of it. read_again is set, and the menu then says the data must be read again
     * (Original::Shell.menu_program). Why the pack was not read goes to the console, for whoever
     * made the build. */
    let read_again = false;
    async function kept_pack() {
      const bytes = await store.get();
      if (!bytes) return null;
      const refusal = rg_start_file_refusal(bytes, facts.pack_rules.numbers, facts.pack_rules.words);
      if (refusal === null) return bytes;
      read_again = true;
      if (typeof console !== "undefined") console.info(rg_words_fill(facts.words.kept_pack_refused, { path: facts.pack_file, refusal }));
      return null;
    }

    /* What the player chose on the menu, played with its cursor starting on +line+ (the menu's start
     * file is that byte, then 1 when the kept pack is one this build does not read):
     * { choice, line }, the choice "load_rom" or "settings" and the line the cursor was left on, or
     * null once stopped. The menu's last picture, the line shown as chosen, stays on the canvas
     * until the next part draws. */
    async function play_menu(settings_open, line) {
      const menu = play(programs.menu, { menuOpen: settings_open, startFile: Uint8Array.of(line, read_again ? 1 : 0) });
      await menu.finished;
      if (stopped) return null;
      const vars = menu.readState().vars;
      const number = vars[facts.menu.choice_variable];
      const choice = number === facts.menu.load_rom ? "load_rom" : number === facts.menu.settings ? "settings" : null;
      return { choice, line: vars[facts.menu.line_variable] };
    }

    /* The pack made from a copy that is one file, checked and unpacked: RgShellRefused in the words
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
      const createPart = programs.unpackings[release.unpacking];
      /* An unpacking split in pieces plays as its split, on as many workers as asked for, one too:
       * the page holds no whole routine for it. */
      const plan = facts.pieces && facts.pieces[release.unpacking];
      const in_worker = plan
        ? rg_shell_unpack_on_workers(plan, programs.workers, bytes, facts.unpacking, facts.bar,
                                     rg_shell_worker_count(programs.unpackWorkers), host.canvas)
        : rg_shell_unpack_in_worker(createPart, bytes, facts.unpacking, host.canvas);
      if (in_worker) current = in_worker;
      const result = await (in_worker ? in_worker.finished : plan ? unpack_split_in_page(plan, bytes) : unpack_in_page(createPart, bytes));
      if (stopped || !result) return null;
      if (result.wentWrong || result.finished !== 1 || result.fault !== 0) {
        throw new RgShellRefused(rg_words_fill(facts.words.unpacking_stopped, { named, fault: result.fault }));
      }
      return rg_shell_pack_for(facts, sha1, result.bytes);
    }

    /* The same answer from the unpacking played in the page, where the browser starts no worker:
     * the page does not answer while the routine works between two waits for a frame. */
    async function unpack_in_page(createPart, bytes) {
      const unpacking = play(createPart, { startFile: bytes, uncapped: true, menu: false });
      const result = await unpacking.finished;
      const state = unpacking.readState({ byteListsPacked: true });
      return { wentWrong: result.wentWrong, finished: state.vars[facts.unpacking.finished], fault: state.vars[facts.unpacking.fault_kind],
               bytes: state.lists[facts.unpacking.bytes] || new Uint8Array(0) };
    }

    /* The same for a split, where the browser starts no worker: its jobs played in the page one
     * after another, the main program first. */
    async function unpack_split_in_page(plan, bytes) {
      const jobs = [{ program: plan.main, number: null }, ...plan.pieces.map((piece) => ({ program: piece.program, number: piece.number }))];
      const ended = [];
      for (const job of jobs) {
        const start_file = job.number === null ? bytes : rg_shell_piece_start_file(bytes, job.number);
        const part = play(programs.workers[job.program], { startFile: start_file, uncapped: true, menu: false });
        const result = await part.finished;
        if (stopped) return null;
        const state = part.readState({ byteListsPacked: true });
        ended.push({ wentWrong: result.wentWrong, finished: state.vars[facts.unpacking.finished],
                     fault: state.vars[facts.unpacking.fault_kind], bytes: state.lists[facts.unpacking.bytes] || new Uint8Array(0) });
      }
      return rg_shell_join_split(plan, ended);
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
      let line = 0;
      while (!pack) {
        const chosen = await play_menu(settings_open, line);
        if (stopped || !chosen) return;
        line = chosen.line;
        settings_open = chosen.choice === "settings";
        if (chosen.choice === "load_rom") pack = await load_copy();
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
