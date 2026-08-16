SH1MMER Reworked - Automation

This document explains the high-level automation helpers added to the Reworked branch.

Files added:
- tools/automate.sh - a wrapper to run common sequences (build-bw, build-legacy, build-all)
- Dockerfile - a minimal image for a reproducible environment to run linting and helper tools (note: using loop devices requires extra privileges)
- .github/workflows/ci.yml - CI that runs shfmt and shellcheck, plus basic safety checks on PRs

Why these changes
- Automating common sequences reduces manual repetition and groups steps into a single command (build-all) so you don't have to run wax commands one-by-one.
- CI catches shell formatting and obvious issues early and ensures future changes remain tidy.
- Dockerfile provides a common environment for contributors who may not have all tools preinstalled.

Next recommended steps
1. Add more automation subcommands to tools/automate.sh that map to workflows you use frequently (e.g., `inject-firmware`, `build-devshim`, `bundle-release`).
2. Add integration tests (in a separate protected environment) that exercise wax.sh against small sample images. These should run off of dedicated test images in CI runners with privileged access (carefully managed).
3. Decide how to handle large binary payloads (mrchromebox.tar.gz, buildroot rootfs, wasm). Consider moving them to Releases or using Git LFS to reduce clone size.
4. For compatibility with newer ChromeOS versions we should:
   - Add tests that detect firmware/kernel version and patch levels in target images
   - Encapsulate device-specific workarounds per-board and make them pluggable
   - Maintain a compatibility matrix and scripts to auto-select bypass technique

If you want, I can now:
- Add more automation subcommands that you commonly use.
- Replace large bundled payloads with on-demand downloaders and small shims that fetch them from verified releases.
- Start a compatibility matrix and implement automatic detection of device r# (r111/r114 etc.) from an input image and select the correct bypass strategy.

Reply with which of the next steps you'd like me to implement first (e.g., "move payloads to on-demand downloads", "add automatic firmware/version detection", or "expand automate.sh with X commands") and I'll continue on Reworked branch.
