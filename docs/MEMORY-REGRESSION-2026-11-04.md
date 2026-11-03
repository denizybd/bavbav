# Memory regression: 0.16.4 (79)

macOS Jetsam reports identified Bavbav build 79 as the largest process during a
memory exhaustion incident. Its accounted lifetime peak was 3,459,182 pages of
16,384 bytes, approximately 52.78 GiB. The executable UUID matched the installed
build 79. This is process-accounted memory, including compressed pages; it is
not 52 GiB of physically resident RAM on a 16 GiB Mac. Restarting cleared the
allocations but did not correct their source.

A fresh build 79 process showed millions of Foundation strings and dictionaries
and many 16 KiB data buffers. SwiftUI's AttributeGraph allocations were small by
comparison. The Workspace output reader ran a single dispatch work item for the
entire child lifetime. FileHandle reads and JSONSerialization produced temporary
Objective-C objects without an inner autorelease pool, allowing them to survive
until the reader returned. Coalescing pending snapshots did not release those
temporary objects.

## Reproduction

A disposable child emitted 17 batches of 4 MiB JSON data through the actual
native BackendClient, with a reply barrier after each batch. The child remained
alive during measurement. The probe measured `task_vm_info.phys_footprint`,
which includes compressed memory, rather than virtual address space or RSS
alone. It used synthetic content and did not access the paired user store.

| Reader | Initial footprint | Final footprint | Growth |
| --- | ---: | ---: | ---: |
| Before fix | 12.0 MiB | 163.5 MiB | 151.5 MiB |
| Scoped read and frame pools | 2.50 MiB | 2.77 MiB | 0.27 MiB |

All 17 reply barriers remained ordered. The old allocations fell after closing
the child. The corrected reader reached a plateau while the child was still
alive. This reproduces and corrects the lifetime-retention mechanism; a short
synthetic regression is not a claim that every long-running application path
has been exhaustively proven leak-free.

The permanent native check was also compiled against the saved unfixed reader:
it failed with an 87.05 MiB warmed footprint range. All 19 checks passed with
the corrected reader, whose warmed range was 49,152 bytes. Core and protocol
fixtures passed with a real 100 MiB unterminated stream, released-buffer
assertions, subsequent reconnection, and a valid 16 MiB response.

## Changes in 0.16.5 (80)

- Drain temporary objects after each Workspace pipe read and decoded frame.
- Scope Codex stream parsing and rollout-file decoding similarly.
- Convert history pages to compact display messages before fetching older
  pages, instead of retaining all raw tool logs and attachment payloads.
- Bound each Codex protocol frame to 96 MiB. Oversized or unterminated frames
  fail the connection explicitly and release the buffer; they are not silently
  truncated. A subsequent operation can reconnect.

The native sustained-reader regression checks footprint growth while the child
is alive. Protocol fixtures check an oversized incomplete stream, buffer release,
subsequent reconnection, a valid large frame, and ordered final output at EOF.
These checks are separate from installation, ordinary GUI responsiveness,
hours-long use, and acceptance on a second Mac.
