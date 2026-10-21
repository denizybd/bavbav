# Repository-owned Local AI runtime

Bavbav's offline extension uses the **same model already used on this Mac**:
`huihui_ai/qwen3-abliterated:14b-v2` (Qwen3 14.8B, Q4_K_M). It does not silently
substitute another model or a cloud provider. Model generation is not itself
permission to execute commands: the offline worker and handoff coordinator own
the separate task, tool, verification, and recovery policies.

## Physical files and GitHub

The runtime, libraries, licenses, model manifest, and model weights physically
live **inside the Bavbav checkout** under `Runtime/LocalAI/`. This directory is
private to the current user, ignored by Git, and is not copied into a public
source release or the ordinary application bundle. GitHub receives the setup
code and `Resources/LocalAI/model-lock.json`, not a 9 GB binary weight commit.
The application must retain the configured checkout path when packaged.

```text
bavbav/
  Resources/LocalAI/model-lock.json    tracked integrity/source/version lock
  scripts/local-ai-setup.py            tracked standard-library installer
  Runtime/LocalAI/                     untracked, mode 0700
    runtime/                          pinned Ollama + dependent libraries
    models/blobs/                     SHA256-addressed model assets
    models/manifests/                  exact pinned local model manifest
    installation.json                 verified installation receipt
    server.json                       owned PID/executable/start identity
    server.log                        private diagnostics, not chat storage
    home/                             isolated provider home directory
    tmp/                              isolated temporary files
```

The manifest wrapper's SHA256 is
`6368f3f98026a670902f23e9650bf6ab0b576de2c0fa9ba3f17795a4d713ff0e`.
Ollama's API reports
`fa0eaa5098bc2a63a999917635534a3b0722c777346c81cc085fde4240b1e2cf`:
this is the original model manifest, embedded as the wrapper's final layer.
Both manifests and their exact config, template, parameters, license, and weight
digests are pinned. This is not a different model or a tag-only comparison.
The weight layer is 9,001,748,832 bytes; the complete runtime resources are about
566 MB before APFS sharing/compression. Context allocation is additional RAM.

## CLI contract

Python 3 is required. No pip package, root access, shell installer, or separate
OpenAI API key is required. Global options precede the action. Standard output
is one JSON object; progress/errors intended for humans go to standard error.

```sh
python3 scripts/local-ai-setup.py --repo /absolute/path/to/bavbav status
python3 scripts/local-ai-setup.py --repo /absolute/path/to/bavbav setup
python3 scripts/local-ai-setup.py --repo /absolute/path/to/bavbav verify
python3 scripts/local-ai-setup.py --repo /absolute/path/to/bavbav start
python3 scripts/local-ai-setup.py --repo /absolute/path/to/bavbav stop
python3 scripts/local-ai-setup.py --repo /absolute/path/to/bavbav check
```

`setup` first copies the pinned local Ollama application resources and reuses
the exact existing `~/.ollama/models` files. On macOS it attempts APFS
copy-on-write cloning with `cp -c`, never hard links. A filesystem without
cloning support gets an independent copy after a free-space check. Source and
destination SHA256 hashes and byte counts are verified. The original global
installation, model store, daemon, and active jobs are never changed or stopped.

Missing assets do not cause an automatic network loop. An explicit setup choice
may authorize the following operation:

```sh
python3 scripts/local-ai-setup.py --repo /absolute/path/to/bavbav setup --allow-download
```

It downloads only the pinned official Ollama 0.40.6 archive and the pinned public
model blobs over HTTPS, with exact SHA256/size checks. Interrupted downloads
remain resumable `.partial` files; they are not installed until verified. A
retry is explicit, and a missing/offline registry produces a clear JSON error.
No installer script or downloaded shell command is executed. Runtime archive
traversal, hard links, and unexpected special files are rejected; only pinned
relative library aliases are recreated. For offline installation, provisioning
must have completed while the exact local assets or download access existed.

`status` does not start a daemon or load the model. It reports `installed`,
`running`, `model`, `modelDigest`, `runtimeVersion`, `root`, `endpoint`,
`ownedPID`, `loadedModels`, and `reason`. `verify` streams through every installed
asset's SHA256; normal startup reuses the installation receipt for files whose
size and nanosecond modification stamp are unchanged. Changing the lock or an
asset invalidates this fast path. An installation is not evidence of model
quality or a successfully completed handoff.

## Lifecycle and memory boundaries

The owned server listens only on `http://127.0.0.1:11439`, never all interfaces.
Port 11434 is the user's separate global service and is never used for Bavbav
production work. The endpoint is loopback-only, not a network service or a
security boundary against other processes already running as the same user.

`start` requires a verified installation, rejects a port occupied by an unowned
process, and starts the repository's own executable with isolated `HOME`, model,
and temporary paths. Inherited proxy credentials, provider tokens, API keys, and
global Ollama environment settings are not passed through. It sets:

- `OLLAMA_NO_CLOUD=1`, no cloud fallback or remote model selection;
- one parallel request and one resident model;
- context length 4096 by default, with worker requests bounded to at most 8192;
- queue size one and default `keep_alive=0`;
- no model preload: starting the process does not load 9 GB into RAM.

The worker should explicitly send the exact model, bounded `num_ctx` and output
limits, and `keep_alive: 0` when its job finishes. Streaming cancellation must
close the request rather than starting a second request on top. On a 16 GB Mac,
an already-loaded global 14B model may still compete for memory. This release
does not automatically detect other applications' resident models or report
their RAM usage; check that separately. It never stops their work without permission.

`stop` signals only a verified owned PID whose executable path, UID, and process
start identity match the persisted receipt. On macOS, health checks also verify
that this PID owns the loopback listener. It never sends a process-group signal,
force-kills an unresponsive process, or manipulates a shared global daemon.
Private runtime paths reject symbolic-link traversal and files writable by other
users. Setup/start/stop operations use a nonblocking file lock to prevent races.

## Provenance and redistribution

- [Ollama 0.40.6 source/release](https://github.com/ollama/ollama/tree/v0.40.6)
- [Pinned official Darwin runtime archive](https://github.com/ollama/ollama/releases/download/v0.40.6/ollama-darwin.tgz)
- [Ollama MIT license](https://github.com/ollama/ollama/blob/v0.40.6/LICENSE)
- [Model tag and publisher](https://ollama.com/huihui_ai/qwen3-abliterated:14b-v2)
- [Upstream model repository](https://huggingface.co/huihui-ai/Qwen3-14B-abliterated-v2)
- [Official provider environment and memory guidance](https://docs.ollama.com/faq)

The model license layer is Apache-2.0 (SHA256
`d18a5cc71b84bc4af394a31116bd3932b42241de70c77d2b76d69a314ec8aa12`).
Ollama's MIT text and bundled third-party notices are retained with the local
runtime. Locking a community model's bytes is an integrity measure, not a safety
or quality certification. This model's abliterated behavior does not override
Bavbav's task/tool boundaries.

## Verification levels

`check` runs small temporary fixtures only. It checks private files, atomic
records, traversal rejection, hashing, independent copying, and digest failures;
it does not copy the real model, contact the internet, stop any daemon, or run
inference. Real setup, local API health, actual inference, RAM placement, task
handoff, cancellation, and application UI acceptance must be recorded separately.
