# HSpec Core and Fotufilm parameter mapping

This draft compares the shipped Fotufilm decoder and all 40 stock definitions in the Film catalogs with Matrix’s HSpec v2.0 production reader, validation and renderer. It proposes no binary fields or chunk changes.

## Findings

HSpec Core can carry the spectral recipe across apps. Its fields include profile identity and provenance, relative capture sensitivity and speed, net characteristic response, dye absorption, base density, capture-to-dye mixing, a specified inhibition law, scanner illumination and positive conversion gamma. Exact field interchange and equivalent rendering are separate tests. Fotufilm and Matrix currently apply different reconstruction, development and receiving models.

The 10 Hibiscus Originals all use Fotufilm schema 2 with separated base and analytic curves. The 30 Fotufilm entries use schema 1 (2), 3 (7), or 4 (21). Their spectral records use `separatedBase` (20), `samples` (9), or `measured` (1). Of the 30, 27 have sampled characteristic curves, 21 have at least one decreasing sample interval, and 3 carry signed dye coefficients. All three signed cases are in the set with decreasing intervals: CineStill 800T, Vision3 250D, and Vision3 500T. Three stocks are monochrome, six have the reversal flag, and two of those are integral instant prints. These material differences matter independently of the profile’s display name.

For review, use Core for transferable spectral data now, keep the current Matrix metadata under `MATX`, and leave `FOTU` unassigned in the implementation. Grain, halation, capture illumination and several other missing concepts can be described independently of either engine. If interchange needs them, define units, calibration, defaults and compatibility in a reviewed portable model. Only a specifically needed Fotufilm operator with no portable equivalent would justify considering the proposed extension. A wrapper for Fotufilm’s stock JSON would duplicate Core values and bind interchange to upstream schema revisions.

## HSpec contract

- Required chunk `1` contains the binary property list for the production spectral specification. Required chunk `2` is the mutually exclusive legacy illustrative payload. HSpec envelope version and Core model version are separate from a recipe’s revision.
- Core validates 81 samples across 380–780 nm in 5 nm steps, up to eight independent capture and dye records, sensitivity in 0…1, and nonnegative dye and base absorption. It accepts one to four analytic populations per response or up to 1,024 bounded, monotonically nondecreasing net-density samples starting at zero. The response must form density at reference log exposure zero. The mixing and inhibition rows must contain nonnegative coefficients with row totals at most one.
- `MATX` (`0x4D415458`) is an optional Matrix metadata chunk. Its payload has `summary`, `author`, `filmFormat`, `defaults` and optional `grainCharacter`. These editor fields remain Matrix metadata. For example its `Grain`, `Grain size`, `Halation` and `Fine/Irregular/Clustered` preferences have no calibrated conversion to Fotufilm’s stock parameters.
- Matrix preserves unknown optional chunks when it re-encodes a production recipe. A reader can preserve an optional chunk without interpreting it. `FOTU` (`0x464F5455`) is a proposal awaiting review. The identifiers are UInt32 values encoded little-endian in the envelope.

## Fotufilm field map

**Core** means an existing field with equivalent data semantics, subject to range, axis and model checks. **Projection** means a subset or conversion with a stated limitation. **Gap** means no equivalent field exists in Core today. **Metadata** and **Local** indicate fields whose value is descriptive or belongs to the source format or app. Counts show how many definitions explicitly contain each field in the **Originals / Fotufilm** catalogs. A zero count can still imply an engine default. Counts establish presence, while the render notes below describe actual use.

| Fotufilm stock fields | Present | Existing HSpec counterpart and limits |
| --- | ---: | --- |
| `schemaVersion` | 10 / 30 | Local. Use the Fotufilm version to decode the source. The HSpec envelope, model and recipe revision each have their own version. |
| `id` | 10 / 30 | Projection. Assign a stable Core UUID from source namespace and stock key. Preserve the source slug in provenance where useful for traceability. |
| `name` | 10 / 30 | Core `name`. |
| `subtitle` | 10 / 30 | Metadata. Free-form display copy can contribute to a Matrix summary. It should play no part in classifying material or selecting a renderer. |
| `nativeFormatID` | 10 / 30 | Metadata. Map the display gauge to `MATX.filmFormat` where recognized. Core has no physical frame dimensions. Gauge-dependent effects need explicit units if standardized. |
| `isMonochrome` | 10 / 30 | Projection. Map the family label to `Monochrome` and carry the underlying sensitivities and neutral absorption. Matrix’s monochrome handling and Fotufilm’s single-record development can differ. |
| `isReversal` | 10 / 30 | Gap for rendering. Family can describe a slide; Core’s current positive conversion is a negative inversion and does not define direct-positive output. |
| `isReflectionPrint` | 0 / 2 | Gap for rendering. A family label describes instant stock but Core has no reflective media model. |
| `isExample` | 0 / 0 | Local catalog or authoring flag. |
| `spectralLineage` | 0 / 0 | Metadata. Carry source and modification history in Core provenance. Fotufilm’s lineage lookup and export rules remain app behavior. |
| `referenceIlluminantKelvin` | 10 / 6 | Gap. This is capture/emulsion reference white. Core `scanningIlluminant` describes light transmitted through developed film. A constant `logSpeed` is insufficient to reproduce a different capture illuminant. |
| `sensitivity` | 10 / 30 | Gap for the compact RGB capture matrix. Core integrates an SPD against wavelength samples. The RGB coefficients are bound to Fotufilm’s fallback; they are distinct from Core `mixing`, which maps developed records into dye amounts. |
| `sensitivityFloor` | 0 / 2 | Projection. Fold the floor into the resolved wavelength samples before exporting `layers[].sensitivity`. The source floor knob has no Core field. |
| `spectral` | 10 / 30 | Core for resolved, bounded relative sensitivity, nonnegative absorption and minimum-density samples. See the spectral mapping below for source variants. |
| `curves` | 10 / 30 | Core for in-range analytic populations or monotonic net-density samples. Local extrema and some Fotufilm curve domains cannot be transported precisely. See the curve mapping below. |
| `donorLayers` | 0 / 7 | Projection for each donor’s spectral sensitivity and response alone. Core cannot express the donor’s release law, physical depth, lateral spread, or a distinct donor operator. Adding a Core layer with no dye contribution does not create those semantics. |
| `flare` | 10 / 30 | Gap. Flare changes exposure through scattered scene light. Base density is intrinsic film attenuation, a different quantity. |
| `emulsionDiffusionMM` | 10 / 30 | Gap. Per-record spatial spread in millimetres. |
| `emulsionDiffusionSecondaryMM`, `emulsionDiffusionPrimaryShare` | 0 / 20 each | Gap. The second spatial scale and its mix. |
| `mtfLumaShare`, `lumaDiffusionMM` | 0 / 0 each | Gap. Luminance separation and its spatial blur scale. |
| `couplerInhibition` | 10 / 30 | Gap for the operator despite similar matrix shape. Matrix divides developed density by a simultaneous bounded density-domain denominator. Fotufilm releases inhibitors, can diffuse them spatially, and applies them in its development/log-exposure model. Copying coefficients into Core `inhibition` would change meaning. Zero effect can be expressed by zero coefficients. |
| `couplerReleaseGamma`, `couplerReleaseKappa` | 0 / 21 each | Gap. Hill exponent and competitive QDI ratio belong to a specific release model. |
| `couplerGeometry` | 0 / 21 | Gap. Its physical inputs and their derived Fotufilm inhibition matrix have no equivalent Core operator. Its internal members are listed below. |
| `couplerDiffusionMM` | 10 / 30 | Gap. Lateral inhibitor spread. |
| `chromaticFringeAmount`, `chromaticFringeRadiusMM` | 0 / 0 each | Gap. Fotufilm’s chromatic adjacency operator. Independent of the FX tab’s Chromatic Drift. |
| `adjacencyStrength`, `adjacencyRadiusMM` | 0 / 30 each | Gap. Physical/spatial edge response. |
| `adjacencyModel` | 0 / 0 | Gap. Engine choice of edge operator. |
| `grainStrength`, `grainSizeMM`, `grainLayerWeights` | 10 / 30 each | Gap. Native amplitude, physical scale and per-record weighting have no Core grain model. Matrix editor values under `MATX` are a separate convention. |
| `grainLumaCorrelation` | 10 / 22 | Gap. Coupling between luminance and record grain. |
| `grainMottleShare`, `grainMottleSizeRatio`, `grainLayerSizeRatio` | 0 / 0 each | Gap. Relative sizes and proportions of grain fields. |
| `grainDensityLaw` | 0 / 2 | Gap. Fotufilm’s named density-to-variance laws and enum values. |
| `grainDensityProfile` | 0 / 30 | Gap. Per-record dye-cloud density response, with `amplitude`, `toeDensity`, `decayDensity`, `humpAmplitude`, `humpDensity` and `humpWidth` coefficients. |
| `crystalGrainPopulation` | 10 / 30 | Gap. `coatingDensityScale`, `radiusSpan` and `sublayerShares` feed the native crystal model. These are separate from the analytic speed populations in Core response curves. |
| `grainReversalProfile`, `grainFogDensity` | 0 / 0 each | Gap. Reversal grain exponent and density shoulder, and native grain-density fog. Core `baseDensity` describes optical base/fog and has no corresponding grain statistics. |
| `granularityReadDensity` | 0 / 4 | Gap. Net versus gross density calibration for the native granularity measure. |
| `halationStrength` | 10 / 30 | Gap. Per-record returned exposure fractions. |
| `halationLookScale`, `halationHazeMM` | 0 / 28, 0 / 0 | Gap. Authored return amount multiplier and physical support scatter. |
| `halationProfile`, `estimatedHalationProfile` | 0 / 1, 0 / 25 | Gap. Calibrated or opt-in estimated spatial/angular return profile. |
| `halationReturnMatrix` | 0 / 26 | Gap. Returned light routing is distinct from dye mixing and inhibition. |
| `layeredTransport` | 0 / 28 | Gap. Coating stack construction and the conditional-launch optical model are outside current Core. |
| `paperCurve`, `paperMidDensity` | 10 / 30, 0 / 30 | Gap for paper behavior. Core `positiveGamma` is the exponent of its own inversion and cannot replace a paper toe, shoulder, minimum density or reference print density. |
| `nativePrintMedium` | 0 / 7 | Gap. Default Fotufilm receiver/medium identifier with no equivalent Core receiver selector. |
| `reciprocityFailure` | 0 / 26 | Gap. Duration-dependent law. At one declared shutter time a converted response could include a constant offset or evaluated curve for that time only. |
| `development` | 0 / 24 | Gap for the process table. One named condition’s evaluated spectral response can be the basis for a separate Core recipe, with its origin in provenance. A Core file cannot carry the full Fotufilm development table. |
| `sheetNotches`, `edgePrinting` | 0 / 1, 0 / 25 | Metadata outside Core and the existing `MATX` contract. These describe physical stock identification for optional framing or documentation. They are unrelated to spectral rendering. |

### Spectral and curve fields

| Source field | Mapping and check |
| --- | --- |
| `spectral.kind` | Source discriminant. Materialize the definition into wavelength-domain data before deciding what can be represented. Core has fields for the materialized data. |
| `spectral.layerSensitivity` | `layers[].sensitivity` when samples are on the same 81-band grid and within range. An out-of-range row can use a relative normalization if its exposure-reference semantics are documented. Matrix normalizes each layer against its own reference gray. Normalizing the row alone does not recover absolute speed across engines. |
| `spectral.imageDyeDensity` | `dyes` when the values are within Core’s nonnegative absorption model. Clipping negative basis coefficients changes the model. State that explicitly when projecting a signed stock. |
| `spectral.minimumDensity` | `baseDensity` for separated-base records. Legacy total-record data can only supply equivalent base after a defined conversion from the dye basis and base record amounts. The current exporter uses zero when no separate base spectrum is present. That is a fallback. |
| `spectral.dyeFamily`, `peaksNM`, `widthsNM`, `rgbWeights` | Source shorthands for `measured`, `color` and `monochrome`. Export only their materialized wavelength samples if representable. Piecewise interpolation, tail continuation and native model defaults belong to source conversion. Neither generated spectral values nor a Core record encode the original shortcut selector. |
| `curves[].gamma`, `toe`, `toeWidth`, `shoulder`, `shoulderWidth` | Core `layers[].response.populations[]` for equivalent log-exposure reference, units, bounds and formula. Each application normalizes exposure and output in its own model. |
| `curves[].secondary` and its five curve parameters | Additional analytic population under the same assumptions. For sampled response, the sample series is the effective curve. Do not serialize both as competing Core definitions. |
| `curves[].sampled.logExposure`, `density` | Core `response.exposure` and `response.density` after converting density above base and validating Core bounds. Fotufilm accepts local extrema. Core currently rejects a decreasing interval, so taking a running maximum or applying isotonic regression is a projection. The interpolation slopes are derived from samples and are not source data. |
| `curves[].dMin` | Participates in converting raw to net density. HSpec has no independent per-record density floor. For separated-base records copy the supplied base spectrum once. Moving a scalar `dMin` directly into an arbitrary wavelength band would double-count or misstate base. |

### Remaining nested fields

All annotated gaps here refer to current Core. A parameter appearing in more than one native structure keeps the same mapping restriction in each context.

- **`donorLayers[]`.** `name`, `sensitivity` and `curve` can describe a wavelength-domain record, including the curve fields above. `inhibition`, `releaseGamma`, `releaseKappa` and `depthUM` have no equivalent donor operator in Core. A mapping of the record alone would lose its effect.
- **`couplerGeometry`.** `layerDepthUM`, `interlayerTransmission`, `release`, `selfRetention` and `receiverSusceptibility` specify Fotufilm’s vertical coupling calculation. The effective `couplerInhibition` can be derived from these inputs. An interchange design must choose a single canonical representation for any operator it defines.
- **`halationProfile` and `estimatedHalationProfile`.** `roundTripOpticalDepth`, `angularExponent`, `diffuseShare`, `diffuseSigmaMM`, `bounceRetention` and `recordDepthMM` have no Core field. The `estimated` qualifier matters independently of the numbers. A future portable model could describe a calibrated returned-light contribution with a spatial response and explicitly defined units.
- **`layeredTransport`.** `revision`, `kind` and `constructionID` identify the source model and construction. `wavelengthsNM` declares the same sampling positions but does not turn the transport tables into Core spectral layers. `layers[].id`, `thicknessMM`, `refractiveIndex`, `absorptionPerMM`, and `frontIndex`, `rearIndex`, `rearReflectance`, `rearPlateReflectance`, `recordDepthMM`, `angularExponent`, `captureProbability`, `returnedToDirect` and `coreSigmaMM` describe the full physical operator. There is no Core counterpart. Shipped raw records include a `provenance` entry inside this object. The pinned `LayeredTransport` type does not decode that entry as a transport parameter. Retain attribution through profile provenance when relevant.
- **`reciprocityFailure`.** `thresholdSeconds`, `lostStopsPerDecade`, `statedThroughSeconds` and `layerWeights` describe an exposure-duration dependency. Core has no time argument in its recipe evaluation.
- **`development`.** `developer`, `dilution`, `temperatureC`, `agitation`, `source` and `sourcePage` document the native process and can support provenance for a derived recipe. For each `conditions[]`, `stops`, `label`, `timeMinutes`, `exposureIndex`, `basis` and `basisStock` describe its context. `curves`, `donorCurves`, `grainStrength`, `grainSizeMM`, `grainLayerWeights`, `grainFogDensity`, `adjacencyStrength`, `couplerScale` and `couplerGeometry` are condition-specific overrides. Evaluation may yield transferable curves for one condition. Core has no mechanism to select or interpolate these development conditions.
- **`sheetNotches` and `edgePrinting`.** `source`, `notches[].position`, `width`, `depth`, and `formatID`, `sources`, `marks[].text`, `xMM`, `yMM`, `widthMM`, `heightMM`, `dx.part1`, `dx.part2`, `dx.source` describe identifying marks. Current HSpec has no structured field for those. Provenance can retain their source citation when relevant.

### Core fields supplied by the interchange author

Core `model`, UUID and recipe revision are HSpec identity. `family` and descriptive `iso` come from the film catalog and authorship. Core `provenance` carries authorship, sources, license and changes. Neither numeric ISO nor a stock name sets exposure. Core `logSpeed` requires a calibrated relative exposure offset, which the current Film exporter sets to zero. Core `mixing` is currently identity for Film’s three dye-forming records. Core `inhibition` is set to zero in this projection. The 6000 K scanner SPD and `positiveGamma = 1` are projection choices for Matrix, independent of the selected stock’s native reference illuminant, paper and screen receiver.

## Rendering scope and review decisions

Film runs Fotufilm’s screen receiver with `referenceExposure` and the default clump-field grain and legacy halation. Native rendering uses the stock’s exposure response, sensitivity, dye/base, flare, and relevant spatial pipeline, with options and feature availability deciding which paths run. For example the crystal population and layered transport are authored stock data but their dedicated models are not the selected defaults. The native print-medium fallback, push/pull condition tables and reciprocity settings need their corresponding print, development or shutter options. Marks and notches do not drive spectral rendering. Sampling a profile or fitting it for another renderer does not automatically transfer its license or provenance obligations.

The existing exporter peak-normalizes sensitivity, converts sampled response to net density, uses a running maximum for decreasing curves, and clips negative dye coefficients. It sets the neutral projection values above and writes `MATX` metadata. This currently exchanges a Core projection. Film can use an imported projection to identify an equivalent known bundled negative. Unmatched custom spectral files can be stored and re-exported, and do not yet render through a general Core-to-Fotufilm adapter. Saved Kitchen recipes retain the full native definition locally.

For a first portable implementation, prioritize compatible spectral profiles and test import, re-export and rendering separately. Before promising lossless interchange for wider stocks, review whether to standardize signed basis conventions, sampled extrema, material polarity and a capture reference in Core, or explicitly limit those profiles to documented projections. For spatial character, review portable quantities such as an RMS grain reference and a calibrated halation return/scale before considering engine operators. The six examples most useful for comparison are Daylight 100, Mono 400, Tungsten 800, Vision3 500T, Velvia 50 and Instax Mini.

If a narrowly scoped optional operator is eventually reviewed for `FOTU`, reference Core data and serialize only its missing inputs. Do not repeat wavelength samples, curves, dye absorption, name, ISO or provenance. Treat GPU buffers, LUTs generated from recipes, slopes, calibration caches, source paths, live preview state, per-shot exposure/white balance, Color Pad coordinates, accent sampling, Glow derived from the pad and the Kitchen’s drag points and undo history as runtime or local state. The actual authored spectral curves may be exported through Core.

## Sources inspected

- Matrix implementation in `Hibiscus Matrix/Library/Spectrum/SpectrumProfile.swift`, `SpectrumModel.swift` and `HSpecArchive.swift`, `Hibiscus Matrix/Editor/HSpec.swift`, and `Docs/Spectrum Foundation.md`.
- Local Fotufilm implementation in `Upstream/Fotufilm/Sources/FotufilmCore/FilmStockPack.swift`, `FilmStockValidation.swift`, `CharacteristicCurve.swift`, `SampledCharacteristicCurve.swift`, `SpectralModel.swift`, `FilmStock.swift`, `FilmEngine.swift`, `Pipeline.swift` and the supporting optical/chemical model types. [Upstream profile source](https://github.com/DhaliwalX/fotufilm-engine/blob/main/Sources/FotufilmCore/FilmStockPack.swift)
- Hibiscus Film inputs include the two catalogs and their referenced JSON under `Hibiscus Film/FilmProfiles.bundle`, plus `Profiles/KitchenSpectrum.swift`, `FilmProfileExchange.swift` and `FotufilmRenderer.swift`.
