# Contributing to Hibiscus Film

Contributions are welcome. For a substantial feature or a change to camera, FX, or export interactions, start with a GitHub issue so the scope can be discussed before implementation.

## Making changes

- Keep changes focused on the reported problem.
- Use the existing capture, render, and export paths. Keep film simulation in Fotufilm and FX in the Hibiscus Print Engine.
- Preserve existing profile metadata, compatibility, and attribution when changing film recipes or HSpec exchange.
- Keep English and Simplified Chinese strings in sync when changing visible text.

## Testing

Build the **Hibiscus Film** scheme using the [README build instructions](README.md#build). Test the affected flow on a compatible iPhone when practical. Camera Control, RAW, Live Photo, and HPan depend on physical hardware. For export or film rendering changes, check the result as well as the in-app preview.

In your pull request, describe the change, include the checks and device versions you used, and call out behavior that still needs hardware verification. Include sample exports or screenshots for visual changes when available.

## License and branding

Contributions to project source use [MPL-2.0](LICENSE). Keep the original terms and notices with third-party code, profiles, and fonts. For redistributed builds, follow the [branding guidance](README.md#brand-and-marketing-assets).
