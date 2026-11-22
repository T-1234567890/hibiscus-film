# Spectrum profile pack — Fotufilm adaptations

Copyright 2026 MUAStudio Inc. Profile data by **Fotufilm**, https://fotufilm.com.
Source: https://github.com/DhaliwalX/fotufilm-engine
Pinned revision: d534fc99c7eee10a839d3bc4ae26501c286b32a0.

The 20 selected original profiles and their adapted HSpec files in this
app are distributed under **CC BY-SA 4.0**:
https://creativecommons.org/licenses/by-sa/4.0/ . Full terms are in LICENSE.txt.
See UPSTREAM-NOTICE.txt and ../EngineNotices/LICENSING.md for upstream notices.
This is a separately licensed data collection. This notice does not relicense
Matrix application code or replace the engine's separate Apache-2.0 notices.

## Contents and changes

Portra 400, Ektar 100, Gold 200, PRO 400H, C200, UltraMax 400, Aerocolor IV 2460,
CineStill 800T, Eterna 500, Eterna Vivid 500, F-64D, Kodacolor 100, PRO 160NS,
Reala 100, Reala 500D, Superia 200, Superia X-TRA 400, VERITA 200D, Vision3 250D
and Vision3 500T. Original filenames,
source hashes and exact source links are in manifest.json. Original profile files
are unmodified in Originals/. Binary HSpec files are in Adapted/. The project keeps their readable JSON specifications in ProfileSources/Fotufilm/Adapted/. Modified/adapted profile data remains CC BY-SA 4.0.

Matrix adaptation, 2026-11-13:
- Preserve the upstream 81-band sensitivity shapes, image dye absorption and
  separate minimum-density spectrum. Normalize each sensitivity peak; Matrix
  defines exposure relative to its own reference gray.
- Apply least-squares monotonic regression to sampled density traces (maximum
  corrections recorded per layer), subtract their low-exposure floor, and retain
  their log-exposure sample locations. Base/fog is counted in the separate spectrum.
- Use identity capture-to-dye mixing, zero inter-layer inhibition, a 6000 K Planck
  scanner and Matrix model-2 scanner calibration. These are explicit Matrix
  adaptations, not claims of matching Fotufilm's finished rendering.
- Do not translate Fotufilm's paper, development-condition, layered transport,
  grain, diffusion, halation or edge-mark fields into unrelated Matrix parameters.
  The original files retain those fields for provenance, but Matrix does not execute them.
- Assign stable Matrix profile UUIDs and revision 1. Existing photo snapshots keep
  their prior definitions. No upstream updater or ongoing synchronization is added.

Expansion, 2026-11-13: the original six JSON/HSpec definitions remain byte-identical.
All 20 separated-base color-negative profiles in the pinned catalog are included.
CineStill 800T and Vision3 500T have the same upstream color-stage data; their
stock-specific grain/halation distinctions are not included. The selector reports
this limitation rather than inventing a color difference. The other 27 upstream
profiles require additional analytic/sample-base, monochrome or reversal adaptation.

Some Vision3/CineStill dye bases contain negative coefficients. Matrix's current
nonnegative absorption model projects those coefficients to zero; maxima per dye
are recorded in manifest.json and affected HSpec provenance marks this change.
The largest correction is approximately 0.03724 optical-density coefficient.
Originals remain unmodified. This constrained adaptation is not a claim of
identical upstream output. Aerocolor's descriptive speed is nominal ISO A 125,
per Kodak AS-2652; it does not alter simulated exposure:
https://www.kodak.com/content/pdfs/amc/KODAK-AEROCOLOR-IV-Negative-Film-2460-datasheet-en.pdf

The full source distribution retains the readable adaptations and original distribution notes in
`ProfileSources/Fotufilm`. Keep the licensed data available for extraction and redistribution.
Preserve recipients’ licensed rights when distributing the app and its profiles.

No rights in users' rendered photographs are claimed merely for using these
profiles, as the upstream profile notice explicitly states. Stock/manufacturer
names identify the modeled materials; no manufacturer endorsement is implied.

## Hibiscus Film native additions

Hibiscus Film also distributes ten unmodified Fotufilm definitions from the same pinned revision under CC BY-SA 4.0. Their upstream paths, attribution and SHA-256 hashes are recorded in `native-additions.json`. The Matrix adaptation history above applies to its original twenty profiles. Film assigns the library colors and categories in `catalog.json`.
