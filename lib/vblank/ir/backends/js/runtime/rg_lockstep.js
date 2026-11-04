/*
 * ONE MACHINE'S SIDE OF A MATCH PLAYED IN LOCKSTEP, in JavaScript: the same session as Network::Lockstep in
 * Ruby (lib/vblank/network/lockstep.rb), message for message, so a page or a node copy and a Ruby build of
 * one game can share a match. Read that file for why lockstep needs each part.
 *
 * Every machine runs the whole game and sends only each player's buttons for each pass. A machine runs
 * a pass when it holds every player's buttons for it. Pass 1 sets the game up and reads no buttons. A press
 * read at the end of pass p is sent for pass p + 1 + the input delay. Every few passes each machine sends the
 * CRC-32 of its whole game state, and a machine that finds two numbers differ stops with a RgDesync. A player
 * who goes leaves on the same pass on every machine, after the last pass they sent buttons for.
 *
 * NOTHING HERE WAITS. #beginMatch and #exchange are generators: they yield wherever the match must wait for
 * a message, and whoever drives them goes on when a message may have come. A node driver reads the next
 * message from its input and goes on; a page goes on when its connection has a message, and shows the
 * last picture meanwhile, so a pass that waits never freezes the tab.
 *
 * A transport is whatever carries messages: send(message) with a message as the object the wire format
 * (docs/network/protocol.md) writes, receive() giving { from, message } or null, closed(), and id, the
 * machine's number in the room, which is its player number.
 */

const RG_HOST_PLAYER = 1;
const RG_FIRST_READING_PASS = 2;
const RG_WIRE_VERSION = 1;
const RG_MOST_CHAT_CHARACTERS = 200;

/* Raised when two machines' game states differ. report has the pass, the last pass they agreed, and the
 * CRC of each player's machine. */
class RgDesync extends Error {
  constructor(report) {
    const states = Object.keys(report.crcs).sort((a, b) => a - b)
      .map((player) => `player ${player} has 0x${(report.crcs[player] >>> 0).toString(16).toUpperCase().padStart(8, "0")}`).join(", ");
    const agreed = report.last_agreed_pass === 0 ? "At the start the states were the same."
      : `At pass ${report.last_agreed_pass} the states were the same.`;
    super(`The machines in this match disagree. At pass ${report.pass} the game states differ: ${states}. ${agreed} ` +
          `So the first pass that differs is after that, and no later than pass ${report.pass}. ` +
          "To find the cause, play the tape of the match on the interpreter.");
    this.report = report;
  }
}

/* A machine the host would not let in, in plain words. */
class RgRefused extends Error {
  constructor(reason, words) {
    super(words);
    this.reason = reason;
  }
}

/* The link closed before the match began. */
class RgConnectionLost extends Error {
  constructor() { super("The connection closed before the match began. To fix this, check the address and join again."); }
}

const RG_CONSOLE_TITLES = { gba: "Game Boy Advance", gbc: "Game Boy Color", snes: "Super Nintendo", genesis: "Sega Genesis" };

function rg_console_title(console_name) { return RG_CONSOLE_TITLES[console_name] || console_name; }

/* The words a refusal is told, from the reason and the two games (Network::Refused). */
function rg_refusal_words(reason, mine, theirs) {
  switch (reason) {
    case "different_console":
      return `This match is for the ${rg_console_title(theirs.console)}, and your game is built for the ${rg_console_title(mine.console)}. ` +
             `To fix this, build your game for the ${rg_console_title(theirs.console)}.`;
    case "different_game":
      return `This match is a different game. The host plays ${theirs.title}, and you have ${mine.title}. ` +
             "To fix this, use the same game file and the same build as the host.";
    case "started":
      return "This match has started, and nobody can join it now. To fix this, ask the host to start a new match.";
    case "full":
      return "This match is full. To fix this, ask the host for a place in a new match.";
    default:
      return `The host did not let you into the match (${reason}). To fix this, ask the host to start a new match.`;
  }
}

class RgLockstep {
  /* +fingerprint+ is { title, console, digest }. +settings+ is the host's { seed, input_delay,
   * checkpoint_every, players }, or null for a machine that joins and is told them. */
  constructor(transport, fingerprint, settings) {
    this.transport = transport;
    this.fingerprint = fingerprint;
    this.settings = settings;
    this.player = transport.id;
    this.roster = [this.player];
    this.started = false;
    this.begun = false;
    this.events = [];
    this.chat_lines = []; /* what the others have said: { player, text }, in the order it came */
    this.inputs = {};
    this.last_pass_heard = {};
    this.left_after = {};
    this.checkpoints = {};
    this.welcome_seen = false;
    this.refusal = null;
  }

  get seed() { return this.settings.seed; }
  get input_delay() { return this.settings.input_delay; }
  is_host() { return this.player === RG_HOST_PLAYER; }

  /* The handshake. Finishes when the match has started, with the settings every machine now shares. */
  *beginMatch() {
    if (this.begun) return;
    if (this.is_host()) yield* this.gather_players(); else yield* this.ask_to_join();
    this.prepare_passes();
    this.begun = true;
  }

  /* The buttons for the pass that starts, given the end of pass +pass+, as one number a player: finishes
   * with the list. +state_crc+ is called only when this pass is a checkpoint, and gives the CRC-32 of the
   * game's whole state as it now stands. Throws RgDesync when a checkpoint shows two machines differ. */
  *exchange(pass, local_mask, state_crc) {
    this.send_buttons(pass + 1 + this.input_delay, local_mask);
    if (pass % this.settings.checkpoint_every === 0) this.exchange_checkpoint(pass, state_crc());
    const coming = pass + 1;
    yield* this.wait_for_buttons(coming);
    const masks = this.masks_for(coming);
    this.record_departures_on(coming);
    return masks;
  }

  /* Says a line of chat to the others of the room, never into the game: control characters become spaces, a
   * long line is cut, and an empty line says nothing. */
  send_chat(text) {
    const line = this.plain_line(text);
    if (line !== "") this.transport.send({ v: RG_WIRE_VERSION, type: "chat", text: line });
  }

  plain_line(text) { return String(text).replace(/[\u0000-\u001f\u007f-\u009f]/g, " ").trim().slice(0, RG_MOST_CHAT_CHARACTERS); }

  /* Tells the room this machine is going. */
  leave() { /* the transport's own close says so; a driver closes it */ }

  /* --- the handshake --- */

  *gather_players() {
    for (;;) {
      this.receive_pending_messages();
      if (this.roster.length >= this.settings.players) break;
      yield;
    }
    this.started = true;
    this.transport.send({ v: RG_WIRE_VERSION, type: "start", players: this.roster.slice().sort((a, b) => a - b) });
  }

  *ask_to_join() {
    const print = this.fingerprint;
    this.transport.send({ v: RG_WIRE_VERSION, type: "join", game: print.title, console: print.console, digest: print.digest });
    for (;;) {
      this.receive_pending_messages();
      if (this.refusal) {
        throw new RgRefused(this.refusal.reason, rg_refusal_words(this.refusal.reason, print,
          { title: this.refusal.game, console: this.refusal.console, digest: this.refusal.digest }));
      }
      if (this.started) break;
      if (this.transport.closed() && !this.started) throw new RgConnectionLost();
      yield;
    }
  }

  admit_or_refuse(joining, join) {
    const reason = this.refusal_for(join);
    const print = this.fingerprint;
    if (reason) {
      this.events.push({ pass: 0, kind: "refused", player: joining });
      this.transport.send({ v: RG_WIRE_VERSION, type: "refuse", to: joining, reason, game: print.title, console: print.console, digest: print.digest });
    } else {
      this.roster.push(joining);
      this.transport.send({ v: RG_WIRE_VERSION, type: "welcome", to: joining, seed: this.seed, input_delay: this.input_delay,
                            checkpoint_every: this.settings.checkpoint_every, players: this.settings.players });
      this.transport.send({ v: RG_WIRE_VERSION, type: "joined", player: joining });
    }
  }

  refusal_for(theirs) {
    if (this.started) return "started";
    if (theirs.console !== this.fingerprint.console) return "different_console";
    if (theirs.digest !== this.fingerprint.digest) return "different_game";
    if (this.roster.length >= this.settings.players) return "full";
    return null;
  }

  /* --- taking messages in --- */

  receive_pending_messages() {
    for (let envelope = this.transport.receive(); envelope !== null; envelope = this.transport.receive()) {
      this.apply_message(envelope.from, envelope.message);
    }
  }

  apply_message(from, message) {
    switch (message.type) {
      case "join": if (this.is_host()) this.admit_or_refuse(from, message); break;
      case "welcome": if (message.to === this.player) this.adopt_settings(message); break;
      case "refuse": if (message.to === this.player) this.refusal = message; break;
      case "joined": if (!this.roster.includes(message.player)) this.roster.push(message.player); break;
      case "start": this.start_with(message.players); break;
      case "buttons": this.store_buttons(from, message); break;
      case "checkpoint": this.store_checkpoint(from, message); break;
      case "chat": this.chat_lines.push({ player: from, text: this.plain_line(message.text) }); break;
      case "left": this.record_departure(from); break;
      default: break;
    }
  }

  adopt_settings(welcome) {
    this.settings = { seed: welcome.seed, input_delay: welcome.input_delay, checkpoint_every: welcome.checkpoint_every, players: welcome.players };
  }

  /* A machine in the room and not among +players+ does not begin: the host's refusal is on its way. */
  start_with(players) {
    if (!players.includes(this.player)) return;
    this.roster = players.slice();
    this.started = true;
  }

  store_buttons(from, message) {
    (this.inputs[from] ||= {})[message.pass] = message.mask;
    this.last_pass_heard[from] = Math.max(this.last_pass_heard[from] || 0, message.pass);
  }

  /* A player has gone: before the match starts a machine that gave up waiting, during it the player leaves
   * after the last pass they sent buttons for. */
  record_departure(gone) {
    if (!this.roster.includes(gone)) return;
    if (!this.started) { this.roster = this.roster.filter((each) => each !== gone); return; }
    if (this.left_after[gone] === undefined) {
      this.left_after[gone] = this.last_pass_heard[gone] !== undefined ? this.last_pass_heard[gone]
        : RG_FIRST_READING_PASS + this.input_delay - 1;
    }
  }

  /* --- the passes --- */

  prepare_passes() {
    for (const each of this.roster) {
      for (let pass = RG_FIRST_READING_PASS; pass <= RG_FIRST_READING_PASS + this.input_delay - 1; pass++) {
        (this.inputs[each] ||= {})[pass] = 0;
      }
    }
  }

  send_buttons(pass, mask) {
    (this.inputs[this.player] ||= {})[pass] = mask;
    this.transport.send({ v: RG_WIRE_VERSION, type: "buttons", pass, mask });
  }

  *wait_for_buttons(pass) {
    for (;;) {
      this.receive_pending_messages();
      if (this.heard_everyone_for(pass)) return;
      if (this.transport.closed()) {
        for (const each of this.roster) if (each !== this.player) this.record_departure(each);
      } else {
        yield;
      }
    }
  }

  heard_everyone_for(pass) {
    return this.roster.every((each) => (this.inputs[each] && this.inputs[each][pass] !== undefined) || this.gone_by(each, pass));
  }

  gone_by(each, pass) {
    const last = this.left_after[each];
    return last !== undefined && pass > last;
  }

  masks_for(pass) {
    const count = Math.max(...this.roster);
    const masks = [];
    for (let index = 1; index <= count; index++) {
      const heard = this.inputs[index] && this.inputs[index][pass];
      masks.push(heard === undefined ? 0 : heard);
    }
    for (const each of Object.keys(this.inputs)) delete this.inputs[each][pass - 1];
    return masks;
  }

  record_departures_on(pass) {
    for (const [gone, last] of Object.entries(this.left_after)) {
      if (last + 1 === pass) this.events.push({ pass, kind: "left", player: Number(gone) });
    }
  }

  /* --- checkpoints --- */

  exchange_checkpoint(pass, crc) {
    (this.checkpoints[pass] ||= {})[this.player] = crc;
    this.transport.send({ v: RG_WIRE_VERSION, type: "checkpoint", pass, crc });
    this.compare_checkpoint(pass);
  }

  store_checkpoint(from, message) {
    (this.checkpoints[message.pass] ||= {})[from] = message.crc;
    this.compare_checkpoint(message.pass);
  }

  compare_checkpoint(pass) {
    const at = this.checkpoints[pass];
    if (at[this.player] === undefined) return;
    if (new Set(Object.values(at)).size === 1) return;
    throw new RgDesync({ pass, last_agreed_pass: this.last_agreed_before(pass), crcs: Object.assign({}, at) });
  }

  last_agreed_before(pass) {
    let agreed = 0;
    for (const [earlier, crcs] of Object.entries(this.checkpoints)) {
      const number = Number(earlier);
      const values = Object.values(crcs);
      if (number < pass && values.length > 1 && new Set(values).size === 1) agreed = Math.max(agreed, number);
    }
    return agreed;
  }
}

/* The CRC-32 zip files use, of +text+'s UTF-8 bytes: the number Ruby's Zlib.crc32 gives for the same text. */
const rg_crc32_table = (() => {
  const table = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let bit = 0; bit < 8; bit++) c = c & 1 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
    table[n] = c >>> 0;
  }
  return table;
})();

function rg_crc32_of_text(text) {
  const bytes = new TextEncoder().encode(text);
  let crc = 0xFFFFFFFF;
  for (let i = 0; i < bytes.length; i++) crc = rg_crc32_table[(crc ^ bytes[i]) & 0xFF] ^ (crc >>> 8);
  return (crc ^ 0xFFFFFFFF) >>> 0;
}

/* The CRC-32 of the game's whole state as it now stands: every variable and list, written as the windowless
 * run prints them (one line a variable, one a list), as Ruby's rg_live_state_crc does, so one game gives one
 * number on every machine whatever it is written in. */
function rg_match_state_crc() {
  let text = "";
  const previous = rg_active_driver;
  rg_active_driver = {
    dump_variable(name, value) { text += `var ${name} ${value}\n`; },
    dump_list(list) {
      const items = [];
      for (let i = 0; i < list.length; i++) items.push(list.items[rg_list_slot(list, i)]);
      text += `list ${list.name}\t${items.join(" ")}\n`;
    },
    sound_logged() {},
  };
  try {
    rg_game_dump_state();
  } finally {
    rg_active_driver = previous;
  }
  return rg_crc32_of_text(text);
}
