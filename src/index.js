import { imports as fileImports } from "./fmplayer_file_js.js";
import { imports as platformImports } from "./fmdsp_platform_js.js";
import { imports as paccImports } from "./pacc-js.js";
import { imports as wasiImports } from "./wasi.js";

const files = {};

const canvas = document.getElementById("fmdsp");
const gl = canvas.getContext("webgl");

const source = await fetch("main.wasm").then((r) => r.arrayBuffer());
const memory = new WebAssembly.Memory({
  initial: 1 * 1024,
  maximum: 1 * 1024,
  shared: true,
});
const wasm = await WebAssembly.instantiate(source, {
  env: { memory },
  fmplayer_file: fileImports(memory, files),
  fmdsp_platform: platformImports(),
  pacc: paccImports(memory, gl),
  wasi_snapshot_preview1: wasiImports(memory),
}).then((r) => r.instance);
wasm.exports._initialize();

if (wasm.exports.init() !== 1) throw new Error("init failed");

function render() {
  wasm.exports.render();
  requestAnimationFrame(render);
}

requestAnimationFrame(render);

const audioCtx = new AudioContext({
  sampleRate: 55467,
});
await audioCtx.audioWorklet.addModule("audio.js");
const audioNode = new AudioWorkletNode(audioCtx, "audio", {
  numberOfInputs: 0,
  numberOfOutputs: 1,
  outputChannelCount: [2],
  processorOptions: { source, memory },
});
audioNode.connect(audioCtx.destination);

const directory = await fetch("directory.json").then((r) => r.json());
const songSelect = document.getElementById("song-select");
const utf8Encoder = new TextEncoder();
directory.pmd.forEach((song, i) => {
  const container = document.createElement("div");
  songSelect.append(container);
  const radio = document.createElement("input");
  radio.id = `song-${i}`;
  radio.type = "radio";
  radio.name = "song";
  container.append(radio);
  const label = document.createElement("label");
  label.htmlFor = `song-${i}`;
  label.textContent = song.title;
  container.append(label);

  radio.addEventListener("click", async () => {
    const data = await fetch(song.file).then((r) => r.arrayBuffer());
    for (const file in files) delete files[file];
    files[song.file] = new Uint8Array(data);

    const filenameBuf = new Uint8Array(memory.buffer, wasm.exports.getFilenameBuf(), 128);
    filenameBuf.set(utf8Encoder.encode(song.file + "\0"));

    wasm.exports.loadFile();
    audioCtx.resume();
  });
});

canvas.addEventListener("click", () => wasm.exports.togglePaused());
canvas.addEventListener("keydown", (ev) => {
  switch (ev.key) {
  case " ":
    wasm.exports.togglePaused();
    break;
  }
});
