# Spectrum — selective Fotufilm foundation adoption

Adopted 2026-11-13 from [Fotufilm](https://github.com/DhaliwalX/fotufilm-engine),
revision **d534fc99c7eee10a839d3bc4ae26501c286b32a0** (2026-11-12).
Copyright 2026 MUAStudio Inc. Selected engine source is Apache-2.0. See
the original [LICENSE](../../Upstream/Fotufilm/LICENSE) and [NOTICE](../../Upstream/Fotufilm/NOTICE).

Matrix maintains these adaptations independently. No Fotufilm package, submodule,
updater, branding or upstream-maintenance obligation is added.

## Incorporated engine algorithms

`PROVENANCE.json` records the full upstream file hashes and selected symbols.
The following Matrix files contain modified/adapted engine math, under Apache-2.0:

- `Library/Spectrum/SpectrumMath.swift`: stable softplus; additive analytic
  H&D response populations; sampled Hermite response interpolation; wavelength
  integration and dye absorption/transmission with a separate film base.
- `Library/Spectrum/SpectrumMath.h`: native Metal translation of response math
  and optical transmission; reusable by future fused Spectrum kernels.
- `Library/Spectrum/SpectrumFoundation.metal`: bounded batch encoding of exposure,
  response and transmission. Matrix-authored dispatch organization around that math.

Changes from the pinned engine: immutable validated Swift types; throwing input
validation instead of profile-data preconditions; explicit finite/domain bounds;
safe extreme exposure tails; up to four analytic populations; 81 bands over
380–780 nm at 5 nm; trapezoidal integration in nm instead of an implicit sample
sum; separate above-base dye amounts and base/fog, without hard-coding equal
capture/dye counts. The GPU table layout is internal and is not HSpec.
`SpectrumGPU.swift` provides Matrix's caller-owned resource/command-buffer adapter.

The reference harness compares the selected scalar formulas directly with pinned
upstream source. Integration weights are an intentional Matrix convention and
are tested against known integrals separately.

## Deliberately not incorporated

The preserved upstream NOTICE mentions components of the full Fotufilm repository.
Those references do **not** mean that the following material ships in Matrix:

| Component | Upstream declaration / adoption decision |
| --- | --- |
| 47 runtime film profiles | Separate CC BY-SA 4.0 terms. G1 copied none; the subsequent user-authorized profile pack isolates 20 selected negatives and their CC BY-SA adaptations in sibling `Spectrum-Fotufilm-Profiles/`. See that pack’s NOTICE.md and manifest; the other profiles remain excluded. |
| Editor glyphs | Separate CC BY-SA 4.0 terms; **not copied**. |
| Measured-reflectance prior and measurement datasets | Mixed Apache/public-domain/CC BY data provenance; **not copied**. Reconstruction/model/data selection remains G2. |
| CIE observer/illuminant tables; xenon spectrum | Separate data provenance/BSD notice obligations; **not copied**. Verify direct data terms when selecting G2 colorimetric resources. |
| Camera profiles, measured stock/print tables | **Not copied**. Matrix retains native ImageIO/CIRAWFilter input and its ACEScg working representation. |
| Halide compiler/JIT/runtime | **Not linked or bundled**. Adopted scalar formulas compile directly in Swift/Metal; no required Halide API remains. Reassess only for a concrete later algorithm need, with a separate dependency/license review. |
| Apps, plugins, codecs, updater, imagery, branding | **Not copied**. |
| RGB LUT generation/application | **Not copied**. Spectrum's planned core remains direct wavelength-domain processing. |

The license declarations were read from the pinned `LICENSE`, `LICENSING.md`,
`NOTICE` and `THIRD_PARTY_NOTICES.md`, not inferred from a repository badge.
Their hashes are recorded in the manifest. This inventory covers the selected
code only; it is not blanket approval for other upstream material or a claim of
App Store certification.
