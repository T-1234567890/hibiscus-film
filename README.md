<p align="center">
  <img src="Hibiscus%20Film/Hibiscus%20Spatial%20Icon.icon/Assets/Image%203.svg" alt="Hibiscus Film mark" width="150">
</p>

<h1 align="center">Hibiscus Film</h1>
<p align="center"><strong>Film photography on iPhone.</strong></p>

<p align="center">
  <a href="https://github.com/T-1234567890/hibiscus-app">Original Hibiscus</a>
  ·
  <a href="https://fotufilm.com">Fotufilm</a>
</p>

Hibiscus Film is an open-source iPhone camera and photographic effects app built with SwiftUI, AVFoundation, Core Image, and Metal. It pairs the Fotufilm Engine with the live color controls of the original Hibiscus app.

- **Camera** uses the selected film stock in the live viewfinder and develops the capture with that stock.
- **FX** applies print and photographic treatments to imported photos and supported Live Photos.

## Camera

Choose a film stock and see it in the viewfinder before shooting. The camera supports exposure compensation, flash, grid, HEIF, RAW with a developed JPEG companion, and Live Photo, depending on the device and capture mode. The Camera settings include defaults for the stock, capture resolution and capture format.

- **HPan0.5** uses the rear Ultra Wide camera at its highest supported photo resolution. Hold the phone horizontally to capture a single approximately 65:24 photograph.
- **Double Exposure** blends two still captures before the selected film stock is applied.
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

## FX

Import a photograph or Live Photo and choose an effect, then adjust its intensity. Effects include Newsprint, Magazine, Photocopy, Risograph, Duotone, Fiber Print, Warm Print, ASCII, Cyanotype, Engraving, Solarization, Archive, Fade, Chromatic Drift, and Halftone. Effects with selectable inks offer color palettes alongside the intensity control.

The Hibiscus Print Engine handles FX. Fotufilm handles camera film simulation and recipe previews.

## Export

- **Photo Only** saves or shares the developed photograph. Supported Live Photo captures retain their motion.
- **With Film Frame** adds an optional film edge outside the photograph at its rendered resolution. The edge can carry the stock name, an image-derived accent, and the HPan mark. The framed variant of a Live Photo is a still.
- **Auto Save** can save the photo, the framed version, or both. Captured panoramas can also retain the original exposure.

FX exports the processed photograph or a supported processed Live Photo. Source photos remain in the Photos library.

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

The local Fotufilm package includes Halide binaries for iOS devices and Apple silicon Simulator. See the [engine integration notes](Vendor/Fotufilm/INTEGRATION.md) for their source revision and rebuild steps.

The app requests camera, microphone, and Photos access when the corresponding capture or save feature needs it.

## Contributing

See [Contributing](CONTRIBUTING.md) for local testing and pull request guidance.

## License

Hibiscus Film source is licensed under the [Mozilla Public License 2.0](LICENSE). Vendored software, film profiles, and fonts retain their respective licenses. See [NOTICE](NOTICE.txt), the [Fotufilm license](Vendor/Fotufilm/LICENSE), the [film profile notices](ProfileSources/Fotufilm/NOTICE.md), and the [Inter](Hibiscus%20Film/FilmFrameFonts.bundle/Inter-OFL.txt) and [JetBrains Mono](Hibiscus%20Film/FilmFrameFonts.bundle/JetBrainsMono-OFL.txt) licenses.

## Brand and marketing assets

The Hibiscus Film name, icon, and visual identity identify the project. Use your own branding for redistributed forks. Film manufacturer and stock names identify the photographic materials modeled by the profiles.

## Unofficial builds and redistribution

You can build the source for personal use. When redistributing a fork, identify the build as unofficial, credit Hibiscus Film and its upstream projects, and preserve the applicable license and attribution notices.
