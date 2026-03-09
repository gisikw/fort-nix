#!/usr/bin/env python3
"""Strip silence from a 16kHz mono WAV file using Silero VAD v5 (ONNX).

Adapted from silero-vad (MIT License): https://github.com/snakers4/silero-vad
Uses ONNX runtime directly -- no PyTorch dependency.

Parameters tuned for Whisper preprocessing following faster-whisper conventions:
- min_silence_ms=2000: only strip silences longer than 2 seconds
- speech_pad_ms=400: generous padding to avoid clipping speech edges
"""

import sys
import time

import numpy as np
import soundfile as sf
import onnxruntime as ort

SAMPLE_RATE = 16000
WINDOW_SIZE = 512  # v5: 512 samples at 16kHz (32ms per window)


class SileroVAD:
    """Minimal Silero VAD v5 wrapper using ONNX runtime."""

    def __init__(self, model_path):
        opts = ort.SessionOptions()
        opts.inter_op_num_threads = 1
        opts.intra_op_num_threads = 1
        self.session = ort.InferenceSession(
            model_path, sess_options=opts,
            providers=['CPUExecutionProvider']
        )
        self.reset()

    def reset(self):
        self._h = np.zeros((2, 1, 64), dtype=np.float32)
        self._c = np.zeros((2, 1, 64), dtype=np.float32)

    def __call__(self, chunk):
        """Run VAD on a single audio chunk. Returns speech probability."""
        ort_inputs = {
            'input': chunk.reshape(1, -1).astype(np.float32),
            'h': self._h,
            'c': self._c,
            'sr': np.array(SAMPLE_RATE, dtype=np.int64),
        }
        out, self._h, self._c = self.session.run(None, ort_inputs)
        return float(out[0][0])


def get_speech_timestamps(audio, model, threshold=0.5,
                          min_speech_ms=250, min_silence_ms=2000,
                          speech_pad_ms=400):
    """
    Detect speech segments in audio.

    Returns list of dicts with 'start' and 'end' sample indices.
    """
    min_speech_samples = int(SAMPLE_RATE * min_speech_ms / 1000)
    min_silence_samples = int(SAMPLE_RATE * min_silence_ms / 1000)
    speech_pad_samples = int(SAMPLE_RATE * speech_pad_ms / 1000)
    audio_length = len(audio)
    neg_threshold = threshold - 0.15

    # Pad audio to be divisible by window size
    if audio_length % WINDOW_SIZE:
        audio = np.pad(audio, (0, WINDOW_SIZE - audio_length % WINDOW_SIZE))

    model.reset()

    speeches = []
    current_speech = {}
    triggered = False
    temp_end = 0

    for i in range(0, len(audio), WINDOW_SIZE):
        chunk = audio[i:i + WINDOW_SIZE]
        prob = model(chunk)

        if prob >= threshold:
            if temp_end:
                temp_end = 0
            if not triggered:
                triggered = True
                current_speech['start'] = i

        if triggered and prob < neg_threshold:
            if not temp_end:
                temp_end = i
            if i - temp_end >= min_silence_samples:
                if i - current_speech['start'] >= min_speech_samples:
                    current_speech['end'] = temp_end
                    speeches.append(current_speech)
                current_speech = {}
                triggered = False
                temp_end = 0

    # Handle speech at end of audio
    if triggered and audio_length - current_speech['start'] >= min_speech_samples:
        current_speech['end'] = audio_length
        speeches.append(current_speech)

    # Apply padding (without overlapping adjacent segments)
    for i, s in enumerate(speeches):
        s['start'] = int(max(
            0 if i == 0 else speeches[i - 1]['end'],
            s['start'] - speech_pad_samples
        ))
        s['end'] = int(min(
            audio_length if i == len(speeches) - 1 else speeches[i + 1]['start'],
            s['end'] + speech_pad_samples
        ))

    return speeches


def main():
    if len(sys.argv) != 2:
        print("Usage: vad-strip <input.wav>", file=sys.stderr)
        sys.exit(1)

    input_path = sys.argv[1]
    model_path = "@modelPath@"

    start = time.time()

    # Load audio (must be 16kHz mono WAV)
    audio, sr = sf.read(input_path, dtype='float32')
    if sr != SAMPLE_RATE:
        print(f"[vad-strip] expected {SAMPLE_RATE}Hz, got {sr}Hz", file=sys.stderr)
        sys.exit(1)
    if audio.ndim > 1:
        audio = audio[:, 0]  # Take first channel

    original_duration = len(audio) / SAMPLE_RATE

    # Load model and detect speech
    model = SileroVAD(model_path)
    timestamps = get_speech_timestamps(audio, model)

    if not timestamps:
        elapsed = time.time() - start
        print(f"[vad-strip] no speech detected in {original_duration:.1f}s "
              f"(took {elapsed:.1f}s)", file=sys.stderr)
        sys.exit(0)  # Leave file unchanged

    # Concatenate speech segments
    speech_only = np.concatenate([audio[ts['start']:ts['end']] for ts in timestamps])
    stripped_duration = len(speech_only) / SAMPLE_RATE

    # Overwrite input file with speech-only audio
    sf.write(input_path, speech_only, SAMPLE_RATE, subtype='PCM_16')

    elapsed = time.time() - start
    removed = original_duration - stripped_duration
    pct = (removed / original_duration * 100) if original_duration > 0 else 0
    print(f"[vad-strip] {original_duration:.1f}s -> {stripped_duration:.1f}s "
          f"(-{removed:.1f}s / {pct:.0f}% silence, took {elapsed:.1f}s)",
          file=sys.stderr)


if __name__ == "__main__":
    main()
