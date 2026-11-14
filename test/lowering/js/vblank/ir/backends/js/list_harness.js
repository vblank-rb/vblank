/*
 * Makes a list of each width with runtime/rg_list.js and prints, a line each, what keeps its
 * items, how many bytes that takes, and what reads back after a number too big for the slot is
 * set and pushed, so test_js_list_widths.rb can hold the storage and the numbers in one run of
 * node. The runtime files are named on the command line.
 */
"use strict";

const fs = require("fs");

const runtime = process.argv.slice(2).map((path) => fs.readFileSync(path, "utf8")).join("\n");
const lists = new Function(`${runtime}
  return { rg_list_new, rg_list_full, rg_list_set, rg_list_get, rg_list_drop, rg_list_push };`)();

const CAPACITY = 1000;
for (const width of [1, 2, 4]) {
  const list = lists.rg_list_new(CAPACITY, width, `w${width}`);
  lists.rg_list_full(list, 70000);
  lists.rg_list_set(list, 1, 200);
  lists.rg_list_drop(list, 1);
  lists.rg_list_push(list, -70000);
  const read = [0, CAPACITY - 1].map((index) => lists.rg_list_get(list, index));
  console.log(`${width} ${list.items.constructor.name} ${list.items.byteLength} ${read.join(" ")}`);
}
