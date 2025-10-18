import { imports as fileImports } from "./fmplayer_file_js.js";
import { imports as platformImports } from "./fmdsp_platform_js.js";
import { imports as paccImports } from "./pacc-js.js";
import { imports as wasiImports } from "./wasi.js";

const MAX_SAMPLES = 128;

class AudioProcessor extends AudioWorkletProcessor {
  /** @type {WebAssembly.Memory} */ memory;
  /** @type {WebAssembly.Instance} */ wasm;

  constructor({ processorOptions: { source, memory }}) {
    super();

    const module = new WebAssembly.Module(source);
    this.memory = memory;
    this.wasm = new WebAssembly.Instance(module, {
      env: { memory },
      fmplayer_file: fileImports({}),
      fmdsp_platform: platformImports(),
      pacc: paccImports(memory, null),
      wasi_snapshot_preview1: wasiImports(memory),
    });
    // Hacky way to have different stacks for the main "thread" and this worker:
    // this worker gets the first half of the stack, and the main "thread" gets
    // the second half. The stack is located at the beginning of memory.
    this.wasm.exports.__stack_pointer.value /= 2;
  }

  process(_inputs, outputs, _parameters) {
    const output = outputs[0];
    const totalSamples = output[0].length;
    let completedSamples = 0;
    while (completedSamples < totalSamples) {
      const blockSize = Math.min(totalSamples, MAX_SAMPLES);
      this.wasm.exports.mix(blockSize);
      const mixed = new DataView(this.memory.buffer, this.wasm.exports.getAudioBuf());
      for (let i = 0; i < blockSize; i++) {
        output[0][completedSamples + i] = mixed.getInt16(4 * i, true) / 32767;
        output[1][completedSamples + i] = mixed.getInt16(4 * i + 2, true) / 32767;
      }
      completedSamples += blockSize;
    }
    return true;
  }
}

registerProcessor("audio", AudioProcessor);
