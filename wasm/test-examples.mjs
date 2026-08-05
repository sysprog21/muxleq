// Run every runnable code block in the tutorial through the wasm eForth and
// fail on anything the system rejects. Prose that claims a word works is worth
// nothing unless the claim is executed.
//
// Blocks marked <pre class="pseudo"> are illustrations (machine pseudocode, or
// an excerpt whose helper words live in snake.fth) and are skipped.
//
// Blocks share one machine, in document order, because the tutorial builds on
// itself: "cube" is defined in terms of the "square" from the block before it.
import { readFileSync } from "node:fs";
import { Forth } from "./forth.js";

const html = readFileSync(new URL("index.html", import.meta.url), "utf8");
const wasmModule = new WebAssembly.Module(
  readFileSync(process.argv[2] || "build/muxleq.wasm"),
);

const unescape = (s) =>
  s
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&amp;/g, "&")
    .replace(/&quot;/g, '"');

const blocks = [];
const re = /<pre(\s[^>]*)?><code>([\s\S]*?)<\/code><\/pre>/g;
for (let m; (m = re.exec(html)); ) {
  if ((m[1] || "").includes("pseudo")) continue;
  blocks.push(unescape(m[2]));
}

let out = "";
const forth = new Forth(wasmModule, { onOutput: (t) => (out += t) });
const settle = () => {
  if (!forth.runToIdle()) throw new Error("interpreter did not settle");
};
settle();

// Load snake.fth first: the drawing chapter and the game chapter both assume
// the words it defines, and it is itself a block of tutorial code.
const snake = readFileSync(new URL("snake.fth", import.meta.url), "utf8");

let failures = 0;
function runLines(what, text) {
  for (const line of text.split("\n")) {
    if (!line.trim()) continue;
    out = "";
    forth.submit(line);
    settle();
    // eForth ends a throw report with the numeric code, as in " -13?".
    // Matching a bare trailing "?" would fail any example that legitimately
    // prints one, e.g. `." ready? "`.
    if (/(^|\s)-?\d+\?$/.test(out.trim())) {
      failures++;
      console.log(`FAIL ${what}\n  line: ${line}\n  said: ${out.trim()}`);
      return;
    }
  }
  console.log(`ok   ${what}`);
}

runLines("snake.fth compiles", snake);
if (blocks.length < 15) {
  failures++;
  console.log(`FAIL only found ${blocks.length} runnable blocks in index.html`);
}
blocks.forEach((b, i) =>
  runLines(`block ${i + 1}: ${b.split("\n")[0].slice(0, 46)}`, b),
);

console.log(
  failures ? `\n${failures} failure(s)` : `\nall ${blocks.length} tutorial blocks run clean`,
);
process.exit(failures ? 1 : 0);
