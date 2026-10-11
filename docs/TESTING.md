# Testing and measured results

All numbers below were measured during development on one machine (Apple M5, 24 GB,
macOS 26.7) with public, synthetic French speech. They describe that environment only.
The full log in Chinese is in [TESTING.zh-CN.md](TESTING.zh-CN.md).

## How to run

| Command | What it checks | Needs |
|---|---|---|
| `scripts/test.sh` | Unit tests: transcript rules, sentence merging, filler cleanup, uncertain-word rules, storage (autosave, project move, soft delete, permanent delete), Markdown parsing, study-context limits | nothing |
| `scripts/test.sh --bench` | Library save / load timings on 200 one-hour classes | nothing |
| `scripts/test.sh --recognize <audio>` | Recognition output with per-word confidence | French speech assets |
| `scripts/test.sh --pipeline <audio> [--realtime]` | Recognition → translation → save → reload | running model service |
| `scripts/test.sh --model` / `--study` | Translation samples / assistant minutes and cited answers | models |

`scripts/make-sample-audio.sh` synthesises the public test lecture from `Tests/french-sample.txt`.

## Recognition under interference

Word error rate (WER) of Apple's on-device recogniser on the public lecture:

| Condition | WER |
|---|---|
| Clean, music at 0 dB SNR | 0.00 |
| White noise 10 dB / 0 dB | 0.00 / 0.03 |
| Background voices 5 dB / 0 dB / −5 dB | 0.00 / 0.33 / 0.94 |
| Reverberant far field + voices | 0.59 |

Background voices and echo are the real weak points. Tried and **not** adopted because
they gave no measurable gain or made things worse: Apple's speech detector module
(identical WER), contextual vocabulary (identical WER) and Apple's voice isolation as a
pre-filter (white 0 dB 0.03 → 0.20, voices 0 dB 0.33 → 0.86, far field 0.59 → 0.95).

## Translation

- Pauses split sentences: on a 37.8 s lecture with seven mid-sentence pauses, the
  previous pipeline produced 7 lines (4 sentence fragments); the current one produces
  4 lines (1 fragment, where the recogniser missed a full stop), translated as whole
  sentences.
- In older data 14.5 % of lines had used the system fallback; those lines are now
  re-translated with Gemma when the queue is idle. The model service restarted within
  3 s after being killed.

## Uncertain-word marks

Calibrated on 928 words from 16 recordings (3 voices, 8 interference conditions),
aligned to the reference text:

| Rule | Marks per 100 words | Marks that were real errors | Errors marked |
|---|---|---|---|
| Any word, confidence < 0.6 | 11.7 | 47 % | 59 % |
| Content words, confidence < 0.5 (current) | 2.7 | 68 % | 20 % |

Some recognition errors carry high confidence and cannot be marked.

## Not verified

Real classroom recordings (accents, students speaking, room noise), the 12B models in
real time, VoiceOver end to end, multiple displays.
