<p align="center">
  <img src="docs/assets/hibiscus-film-ios27.png" alt="Hibiscus Film app icon rendered for iOS 27" width="150">
</p>

<h1 align="center">Hibiscus Film</h1>
<p align="center"><strong>Film. Print. Repeat.</strong></p>

<p align="center">
  <a href="https://github.com/T-1234567890/hibiscus-app">Original Hibiscus</a>
  ·
  <a href="https://fotufilm.com">Fotufilm</a>
</p>

Hibiscus Film is an open-source iPhone camera and photographic effects app built with SwiftUI, AVFoundation, Core Image, and Metal. It pairs the Fotufilm Engine with the live color controls of the original Hibiscus app.

- **Camera** uses the selected film stock in the live viewfinder and develops the capture with that stock.
- **Effects** applies print and photographic treatments to imported photos and supported Live Photos.

## Camera

Choose a film stock and see it in the viewfinder before shooting. The camera supports exposure compensation, flash, grid, HEIF, RAW with a developed JPEG companion, and Live Photo, depending on the device and capture mode. The Camera settings include defaults for the stock, capture resolution and capture format.

- **HPan0.5** uses the rear Ultra Wide camera at its highest supported photo resolution. Hold the phone horizontally to capture a single approximately 65:24 photograph.
- **Double Exposure** blends two still captures before the selected film stock is applied. Requires Supporter Pack.
- **Style and Accent** use two Color Pads and a shared Strength control. Accent can follow the scene or use a manually chosen color. Moving the Style pad toward highlights adds highlight diffusion.

## Film Library

The library includes 30 bundled Fotufilm stocks and ten independently authored Hibiscus Originals. [Kodak Portra 400](Hibiscus%20Film/FilmProfiles.bundle/Fotufilm/catalog.json) is the starting stock until you choose a different default.

- **Daylight 100**, **Portrait 160**, and **Gold 200** cover clean daylight, softer portraits, and warm color.
- **Pastel 400**, **Street 400**, and **Tungsten 800** cover airy color, stronger midtones, and mixed or artificial light.
- **Mono 100**, **Mono 400**, **Fade 400**, and **Cinema 500** cover fine-grained and documentary monochrome, lifted shadows, and cinematic tonal separation.

See the [original stock notes](ProfileSources/Hibiscus/ORIGINAL-STOCKS.md) for the recipe design and tuning priorities.

### Recipe Kitchen

Start with a blank recipe or a film stock. Edit characteristic and channel curves, tune grain and halation, preview with the Fotufilm Engine, and save the base recipe to the Film Library.

### HSpec

Import and export compatible `.hspec` base recipes from Settings and the Film Library. Imported archives retain their original bytes for exchange. Film can render an imported archive when its spectral data matches a supported native stock.

Kitchen exports carry the supported spectral recipe and metadata. Engine-specific grain and halation settings and Color Pad positions stay in the local recipe or its local adjustments. See the [HSpec parameter mapping](ProfileSources/Hibiscus/HSPEC-PARAMETER-MAPPING.md).

## Effects

Import a photograph or Live Photo and choose an effect, then adjust its intensity. Effects with selectable inks offer color palettes alongside the intensity control.

- **Newsprint** — coarse newspaper dots and ink spread.
- **Magazine** — rich print color with fine CMYK-style screening.
- **Photocopy** — high-contrast monochrome with rough toner.
- **Risograph** — layered inks with offset registration.
- **Duotone** — two-ink photographic tones.
- **Fiber Print** — restrained tones and a fiber-paper surface.
- **Warm Print** — warm paper and softened photographic tones.
- **ASCII** — characters shaped by the photo’s tones and colors.
- **Cyanotype** — blue-print tones with selectable ink colors.
- **Engraving** — etched lines that follow the image’s tones.
- **Solarization** — partial tonal inversion.
- **Archive** — subdued color and soft contrast.
- **Fade** — lifted blacks and softened contrast.
- **Chromatic Drift** — controlled offsets between color channels.
- **Halftone** — visible print dots shaped by photographic tones.

The Hibiscus Print Engine handles Effects. Fotufilm handles camera film simulation and recipe previews.

## Supporter Pack and community support

Hibiscus Film’s open-source code includes **Supporter Pack**. The $6.99 USD one-time purchase helps sustain the project and unlocks Recipe Kitchen, Double Exposure, and exports for seven additional Effects. Standard camera capture is free. **Support Hibiscus** is a separate way to contribute voluntarily.

Supporter Pack is locked until a purchase is verified, including in self-built copies. To remove the paywall from your own build, edit the source before building.

## Export

- **Photo Only** saves or shares the developed photograph. Supported Live Photo captures retain their motion.
- **With Film Frame** adds an optional film edge with a rounded photo opening. Standard frames show the stock name and available capture ISO above the photo, with the arrow and frame number at opposite ends of the lower edge. HPan frames center the available capture ISO above the photo and carry the HPan mark below. Live Photo exports apply the same frame to the still and motion while preserving audio. The film edge is inspired by [SpektraLab’s Film Edge](https://spektralab.app/user_guide/).
- **Auto Save** can save the photo, the framed version, or both. Captured panoramas can also retain the original exposure.

Effects exports the processed photograph or a supported processed Live Photo. Source photos remain in the Photos library.

## Requirements

- Xcode 27.2, the toolchain used to verify this project
- iOS 18.0 or later
- A physical iPhone for camera and hardware validation, with a rear Ultra Wide camera for HPan
- Apple silicon for the bundled Simulator build

Hibiscus Film uses native Liquid Glass on iOS 26 and later, with a system-material fallback on earlier supported versions. The app interface is available in English and Simplified Chinese.

## Build

Open `Hibiscus Film.xcodeproj` in Xcode and select the **Hibiscus Film** scheme. For a physical iPhone build, select your own signing team and a bundle identifier available to that team.

For a compile check without code signing:

```sh
xcodebuild \
  -project 'Hibiscus Film.xcodeproj' \
  -scheme 'Hibiscus Film' \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

The local Fotufilm package includes Halide binaries for iOS devices and Apple silicon Simulator. See the [engine integration notes](Upstream/Fotufilm/INTEGRATION.md) for their source revision and rebuild steps.

The app requests camera, microphone, and Photos access when the corresponding capture or save feature needs it.

## Contributing

See [Contributing](CONTRIBUTING.md) for local testing and pull request guidance.

## Component licenses

Each component carries its own license. The project-wide license for original Hibiscus Film source will be selected separately on GitHub. [Attributions and distribution notes](NOTICE.txt)

| Component | Applicable terms |
| --- | --- |
| Covered source adapted from Hibiscus and Hibiscus Matrix | [MPL-2.0](Hibiscus%20Film/MPL-2.0.txt) |
| Fotufilm engine and the adapted spectral math | [Apache-2.0](Upstream/Fotufilm/LICENSE) and [Fotufilm NOTICE](Upstream/Fotufilm/NOTICE) |
| Halide runtime in the prebuilt kernels | [MIT and upstream notices](Hibiscus%20Film/FilmProfiles.bundle/EngineNotices/HALIDE-LICENSE.txt) |
| Fotufilm film profiles and their adaptations, including HSpec | [CC BY-SA 4.0](Hibiscus%20Film/FilmProfiles.bundle/Fotufilm/LICENSE.txt) and [profile attribution and changes](ProfileSources/Fotufilm/NOTICE.md) |
| Reflectance data and the `colour-science` xenon spectrum | [Dataset-specific terms and BSD 3-Clause notice](Upstream/Fotufilm/THIRD_PARTY_NOTICES.md) |
| Inter and JetBrains Mono | SIL OFL 1.1. [Inter notice](Hibiscus%20Film/FilmFrameFonts.bundle/Inter-OFL.txt) and [JetBrains Mono notice](Hibiscus%20Film/FilmFrameFonts.bundle/JetBrainsMono-OFL.txt) |
| Hibiscus Originals recipe data | The recipe metadata identifies CC BY-SA 4.0. [Original-stock proposal](ProfileSources/Hibiscus/ORIGINAL-STOCKS.md) |

## Legal notice

Hibiscus Film uses manufacturer and film stock names only to identify the photographic materials each profile models. All trademarks belong to their respective owners. These references do not imply affiliation with, sponsorship by, or endorsement from the manufacturers.

## Brand and marketing assets

The Hibiscus Film name, icon, and visual identity identify the project. Use your own branding for redistributed forks.

## Unofficial builds and redistribution

You can build the source for personal use. When redistributing a fork, identify the build as unofficial, credit Hibiscus Film and its upstream projects, and preserve the applicable license and attribution notices.
