"use strict";
/*
 * An unpacking played as a web shell's worker plays it (rg_shell_unpacking_worker), in node, timed:
 *
 *   node unpacking_harness.js FACTORY COPY BYTES_LIST OUT
 *
 * FACTORY is a file whose module.exports is the unpacking's createGame, COPY the copy it is handed,
 * and BYTES_LIST the name of the list it writes the pack into. It plays uncapped, handed each frame
 * back by a message as the worker is, writes the pack's bytes to OUT, and prints how long the play
 * took ("played MS") and how many frames it waited for ("frames N").
 */
const fs = require("fs");
const path = require("path");

const [factoryPath, copyPath, bytesList, outPath] = process.argv.slice(2);
const createPart = require(path.resolve(factoryPath));
const canvas = {
  getContext: () => ({
    createImageData: (width, height) => ({ width, height, data: new Uint8ClampedArray(width * height * 4) }),
    putImageData(image) { image.data.slice(); },
  }),
};
const turn = new MessageChannel();
let asked = null;
let frames = 0;
turn.port1.onmessage = () => {
  const tick = asked;
  asked = null;
  frames++;
  if (tick) tick();
};
const host = { ask(tick) { asked = tick; turn.port2.postMessage(null); return 1; }, cancel() { asked = null; } };
const started = process.hrtime.bigint();
const part = createPart({ canvas, frames: host, startFile: new Uint8Array(fs.readFileSync(copyPath)), uncapped: true,
                          menu: false, keys: false, gamepads: false, audio: false, storage: null, pauseWhenUnfocused: false });
part.finished.then((result) => {
  const played = Number(process.hrtime.bigint() - started) / 1e6;
  turn.port1.close();
  if (result.wentWrong) {
    console.error(result.message);
    process.exit(1);
  }
  fs.writeFileSync(outPath, part.readState({ byteListsPacked: true }).lists[bytesList]);
  console.log(`played ${Math.round(played)}`);
  console.log(`frames ${frames}`);
});
