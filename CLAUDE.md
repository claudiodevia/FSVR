# CLAUDE.md

The project's rules for any agent live in AGENTS.md and are imported here whole. Everything below is a
quick map on top of them; where the two ever disagree, AGENTS.md wins.

@AGENTS.md

## Commands away from Windows

`build.bat` is MSVC-only. On macOS and Linux the same work goes through CMake (3.24+, C++17):

```bash
# engine, render_capture and the self checks (no network, no EPROM needed)
cmake -B build/cmake -S . && cmake --build build/cmake --config Release
ctest --test-dir build/cmake -C Release --output-on-failure     # "effects" and "engine"
python3 tools/check_formant.py && python3 tools/check_presets.py  # the rest of build.bat test

# the plug-in (first configure downloads CLAP/VST3/AU SDKs, clap-wrapper, RtAudio/RtMidi, decoders)
cmake -B build/plugin -S . -DFSVR_BUILD_PLUGIN=ON && cmake --build build/plugin --config Release
ctest --test-dir build/plugin -C Release -R "plugin|gui" --output-on-failure

# one offline render, the same flags as fsvr_console's -w path
bin/render_capture -v presets/native/000_Ballad_EP.syx -w out.wav -n 60 -d 3
python3 tools/check_wav.py out.wav 60
```

- On macOS `sh scripts/build-osx.sh <AU|CLAP|VST3|VST2|Standalone|ALL> [test] [install]` wraps the plug-in
  build, logs to `logs/`, and configures with `MACOS_MIN` (default 11.0): Xcode 27's libc++ rejects the
  10.15 that `hollow/cmake/HollowDefaults.cmake` sets, and clap-wrapper builds with `-Werror`.
- `fsvr_console` only builds on Windows (WinMM); elsewhere the engine check is `engine_selftest` and the
  renderer is `bin/render_capture`. `tools/fs1r_render.py` picks between them by running them.
- `tools/regress.py` against the committed `regress_ref.json` fails on macOS/Linux on a clean checkout
  (the reference is a Windows build; `rand()` differs). Fingerprint before your edit with `--update`, keep
  the file aside, compare after, and do not commit the regenerated reference.
- `-DFSVR_MATH=RAW|LUT|CORDIC|HYBRID` picks the sample loop's maths backend (`src/fsvr/fastmath.h`); LUT is
  the default and what the references were made with.
- Everything runnable lands in `bin/` (plug-ins in `bin/<Format>/`), objects and test binaries in `build/`.

## How the engine fits together

```
host / console ──MIDI, sysex──▶ fs1r::Device (src/fs1r.h, src/fsvr/device.cpp)
                                   │  48 kHz always; resampled to the host rate on the way out
                                   ▼
                               struct Synth (src/fs1r/internal.h)
       firmware/ (KNOWN)  midi.cpp ─▶ patch.cpp / controllers.cpp ─▶ notes.cpp (note on, 192.3 Hz tick) ─▶ fseq.cpp
       chips/ (INFERRED)  ymp706.cpp (operators, EG, formant, render) ─▶ vop3_filter.h ─▶ vop3_effects.h
                          constants from cal.h; vop3_core.h / vop3_modules.h are the measured VOP3 core
                          running the firmware's own microcode (ported from tools/vop3_interp.py)
```

- `src/fs1r.h` is the only header the plug-in includes. `fs1r::Device` is audio, MIDI in/out and state as
  bulk dumps; the plug-in never reaches past it.
- `src/fs1r/internal.h` holds the decoded voice/performance formats, the per-channel chip state and
  `struct Synth`, the whole machine. Method bodies sit in `firmware/` or `chips/` by provenance.
- `vop3_core.h` is a port of `tools/vop3_interp.py`, and `tools/vop3_core_check.py` requires the two to be
  bit-identical: change a rule in the Python first, then the C++.
- `plugin/plugin.cpp` is the processor (params ⇄ sysex, morph, program change, worker thread);
  `library.cpp` the bank manager; `audio_decode.cpp` / `audio_fseq.cpp` Import Audio, which writes Fseq
  bytes and renders nothing. `hollow/` is the framework (formats, skin runtime, editor windows);
  `hollow/docs/skin-format.md` is the skin's contract.

## Where to look before changing something

| You want to… | Read first |
|---|---|
| change how the engine sounds | `STATUS.md` (KNOWN/INFERRED/UNKNOWN), `docs/fidelity_plan.md`, the relevant `docs/{aeg,formant,skirt,noise,detune,filter}.md` |
| touch a firmware port | the `FUN_xxxxxxxx` it cites, `docs/ymp706_registers.md`, `docs/midi_dispatch.md` |
| touch a constant in `cal.h` | its comment's source, and the 2026-09-19 entry in `docs/findings.md` |
| work on the effects / VOP3 | `docs/vop3_isa.md`, `docs/vop3_blockers.md`, `docs/vop3_2_microcode.md`, `docs/vop3_2_params.md` |
| change the editor or a param | `docs/editor.md`, `plugin/skin/` (edited in place, not generated), `plugin/generated/README.md` |
| add a measurement | `captures/README.md`, `tools/make_capture_set.py`, `tools/analyze_capture.py` |
| know what behaves differently on purpose | `docs/Differences.md` |

## Notes for working here

- Docs, comments and commit messages are written in plain, measured English prose, with dates in ISO form
  and numbers quoted with their source. Match that voice when you add to `docs/findings.md` or a comment.
- Python tools assume `python` on Windows; on macOS use `python3`. Most firmware tools also need the
  Ghidra database in `../FS1R_DISASM` and the EPROM image, neither of which is in this repo; checks that
  need the EPROM skip themselves.
- The plug-in checks are threaded and can flake on a loaded machine; CI retries them three times. A check
  that fails every rerun is real.
