// Headless check for the WebAssembly build: boot eForth in the wasm VM, run a
// few lines, and assert on the transcript, the stack side channel, and the
// graphics block. Run with: node wasm/test.mjs build/muxleq.wasm
import { readFileSync } from "node:fs";
import { Forth, GFX_WIDTH } from "./forth.js";

const wasmPath = process.argv[2] || "build/muxleq.wasm";
const wasmModule = new WebAssembly.Module(readFileSync(wasmPath));

let out = "";
let stack = null;
let report = null;
const forth = new Forth(wasmModule, {
  onOutput: (t) => (out += t),
  onStack: (s) => ((report = s), (stack = s.items.join(" "))),
});

// A line is done when the image is idle again and, for a line that runs rather
// than compiles, has reported its stack.
function settle(untilStack) {
  for (let i = 0; i < 2000; i++)
    if (forth.runToIdle() && (!untilStack || stack !== null)) return;
}

// Interpret one line. A trailing "keys" string is queued behind the newline, so
// it is waiting when the line's own code goes looking for a keystroke.
function line(src, keys = "") {
  out = "";
  stack = null;
  forth.submit(src, keys);
  settle(true);
  return out;
}

settle(false);

// A dead stack viewer reports nothing at all, so "stack" stays null. Guarding
// here keeps that showing up as a clean failure instead of a TypeError.
const endsWith = (s, want) => s !== null && s.endsWith(want);

let failures = 0;
function check(what, got, want) {
  const ok = want instanceof RegExp ? want.test(got) : got === want;
  if (!ok) {
    failures++;
    console.log(`FAIL ${what}\n  got  ${JSON.stringify(got)}\n  want ${want}`);
  } else {
    console.log(`ok   ${what}`);
  }
}

check("graphics block allocated", forth.graphics > 0, true);

line("1 2 3");
check("stack after pushes", stack, "1 2 3");

line("+ *");
check("stack after arithmetic", stack, "5");

check("dot prints", line(". cr").trim(), "5");
check("stack empties", stack, "");

// A colon definition spans lines: the <ok> hook must stay quiet while
// compiling, then report once the definition closes.
line(": square");
check("no report mid-definition", stack, null);
line("  dup * ;");
line("7 square");
check("colon definition runs", stack, "49");

// Undefined word, not a stack underflow: eForth reports -4 from the
// interpreter's end-of-line ?depth check, so "drop drop drop" only errors
// when the preceding lines happen to have left fewer than three items. A
// typo throws -13 whatever the depth, so this tests what it says it does.
check("error is reported", line("nosuchword"), /-13\?/);

// Graphics: eForth writes cells, the page reads them straight out of the heap.
line("3 5 " + GFX_WIDTH + " * 2 + cells graphics + !");
check("pixel visible to the host", forth.pixels()[5 * GFX_WIDTH + 2], 3);

// The non-blocking key read must answer "nothing waiting" instead of hanging.
check("ekey with no input", line("ekey . cr").trim(), "0");
check("ekey after a keystroke", line("ekey . cr", "A").trim(), "65");

check("see decompiles", line("see square"), /square/);

// The page used to carry stack reports inline as bytes 1 and 2, so a program
// emitting either one hijacked the framing and swallowed its own output. The
// report lives in memory now; every byte on the stream belongs to the user.
const emitted = line("1 emit 2 emit 65 emit 66 emit cr");
check("byte 1 reaches the transcript", emitted.charCodeAt(0), 1);
check("byte 2 reaches the transcript", emitted.charCodeAt(1), 2);
check("output after them is not swallowed", emitted.includes("AB"), true);
line("7 7 +");
check("the stack viewer still works after", endsWith(stack, "14"), true);

// More text than the VM's input queue holds, handed over in two calls. The
// second send must queue behind what the first could not fit, not replace it:
// dropping the remainder truncates a line mid-word and derails everything after.
line("0 0 0 0 0 0 drop drop drop drop drop drop"); // settle to a known place
forth.send("1 drop\n".repeat(800)); // 5600 chars vs a 4096-byte queue
forth.send("7 8 +\n");
settle(true);
check("a send behind a full queue is not dropped", endsWith(stack, "15"), true);

// A file load hands over many lines at once. eForth's error handler reinstates
// the stock "ok" and stops the snapshots, so an error partway through has to be
// noticed even though several more lines ran after it.
line("decimal");
forth.send("nosuchword\n1 2 3\n4 5 +\n");
settle(true);
check("an error mid-batch still repairs the viewer", endsWith(stack, "9"), true);
line("drop drop drop drop");

// eForth's error report can straddle a slice boundary, so matching it against
// one chunk of output missed it entirely. The reporter then stayed uninstalled
// and the viewer was dead for the rest of the session, silently.
const realRetune = forth.retune;
forth.retune = () => {}; // pin the slice so the report really is split
forth.slice = 4096;
line("nosuchword");
line("5 6 +");
check("an error split across slices still repairs", endsWith(stack, "11"), true);
forth.retune = realRetune;
forth.slice = 200000;
line("drop drop");

// A machine that has been reset must actually stop. A scheduled frame used to
// keep the abandoned instance running, writing its output and its stack reports
// into the session that had replaced it.
const doomed = new Forth(wasmModule, {});
doomed.runToIdle();
doomed.send(": spin begin 1 drop again ;\nspin\n");
doomed.pump(5); // leaves it mid-run, with a frame scheduled
check("an abandoned machine has work pending", doomed.running || doomed.pendingFrame !== 0, true);
doomed.stop();
check("a stopped machine cancels its frame", doomed.pendingFrame, 0);
check("a stopped machine refuses to run", doomed.pump(50), false);

// The viewer needs the numeric base to make sense of what .s printed, and the
// signed value behind each item so it can show the same bits other ways. The
// underflow earlier in this run left residue below, hence the slice: that is
// eForth's behavior, not a bug in the report.
line("decimal 255 -1");
check("report carries the base", report.base, 10);
check("report carries values", report.values.slice(-2).join(","), "255,-1");

// Switching base re-prints the very same cells. The text changes, the values
// behind it must not.
line("hex");
check("base change is reported", report.base, 16);
check("items follow the base", report.items.slice(-2).join(" "), "FF -1");
check("values are base-independent", report.values.slice(-2).join(","), "255,-1");
line("decimal");

console.log(failures ? `\n${failures} failure(s)` : "\nall wasm checks passed");
process.exit(failures ? 1 : 0);
