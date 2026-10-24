# Notices

Archidea is distributed under the GNU General Public License v3.0 (see [LICENSE](LICENSE)). It includes or builds on
the following work, each under its own license.

| Component | Where | License |
|---|---|---|
| Chromium | the browser engine (`Chromium Framework.framework`) | BSD-3-Clause and others, see `chrome://credits` |
| ungoogled-chromium and Helium patches | part of the engine | BSD-3-Clause / GPL-3.0 |
| ArdiaCore engine layer, by Mantra Patel ([source](https://github.com/mantrakp04/ardia)) | the engine's Objective-C API and services | GPL-3.0 |
| Browser import readers, by Mantra Patel | `Sources/Import/Readers` | Apache-2.0 (see the folder's `LICENSE` and `NOTICE.md`) |
| uBlock Origin, by Raymond Hill and contributors | the optional built-in blocker | GPL-3.0 |

The engine is prebuilt from the sources above. `vendor/engine/ENGINE` pins the exact build and its checksum, and the
engine release on GitHub ([engine-155.0.8059.84](https://github.com/getarchidea/archidea/releases/tag/engine-155.0.8059.84))
carries its corresponding source next to the binary.
