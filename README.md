# Soundbrenner Pixel

Soundbrenner Pixel is a native macOS app for generating product and campaign imagery with OpenAI or Google's Gemini image API. It combines a written prompt with optional reference images and reusable JSON profiles for products, people, composition, location, and visual style.

The app also includes a Soundbrenner-specific batch workflow for localizing static ads into multiple language and currency markets.

## Requirements

- macOS 14 or newer
- Xcode with a Swift 6.3 or newer toolchain
- An [OpenAI API key](https://platform.openai.com/api-keys), a [Google AI Studio API key](https://aistudio.google.com/app/apikey), or both
- A paid API account or available API credits. Image generation is not free and costs depend on the provider, model, quality, size, and number of outputs.

No API keys, generated images, private profile libraries, or Shopify credentials are included in this repository.

## Install and run

### Xcode

1. Clone the repository:

   ```sh
   git clone https://github.com/Soundbrenner/soundbrenner-pixel.git
   cd soundbrenner-pixel
   ```

2. Open `Soundbrenner Pixel.xcodeproj` in Xcode.
3. Select the **Soundbrenner Pixel** scheme and **My Mac** as the destination.
4. Press **Run**.

For a local development build, code signing can remain disabled. Distribution through TestFlight or the Mac App Store requires your own Apple Developer team and signing configuration.

### Swift command line

You can also build and run the Swift package directly:

```sh
swift build
swift run SoundbrennerPixel
```

The Xcode build is recommended because it uses the app's sandbox entitlements and icon configuration.

## First-time setup

1. Open the generation screen.
2. In **API keys**, paste the key for the provider you want to use:
   - OpenAI models require an OpenAI API key.
   - Nano Banana Pro requires a Gemini API key.
3. Click the corresponding **Save ... key securely** button.
4. Optional: under **Shared JSON folder**, choose an `image generation` folder containing reusable profiles. You do not need Dropbox. Any local or synced folder works.

Both API keys are stored in macOS Keychain. They are not written to the repository or the shared profile folder.

## Generate images

1. Set **Mode** to **Regular**.
2. Enter a prompt.
3. Optionally add reference photos.
4. Choose an image model:
   - OpenAI models expose quality, moderation, and combined resolution presets.
   - Nano Banana Pro exposes independent aspect-ratio and output-size controls.
5. Choose the number of images and output format. JPEG and WebP also expose compression quality.
6. Choose a shot mode:
   - **With model** can use people, model profiles, product references, and all creative layers.
   - **In context** omits model profiles and uses contextual product scenes.
   - **Product on white** creates a clean product image without people or location presets.
   - **Plain** sends only your prompt and manually attached reference images.
7. Optionally select a product, ad angle, promotional context, model, composition, location, and look from the shared profile library.
8. Click **Generate images**.

Completed jobs appear in the gallery. From there you can retry failed jobs, copy their setup or prompt, reveal local files, or export images to Downloads.

## Localize static ads

The ad-localization mode is tailored to Soundbrenner's products and market rules. Other projects can reuse the workflow, but should replace the product list, truth-data sources, and localization prompt in the source code.

1. Set **Mode** to **Ad localization**.
2. Choose a folder containing PNG, JPEG, WebP, HEIC, or TIFF source ads.
3. Select one or more target language and currency markets.
4. Select a product only when the source ad contains that product's price or savings claim.
5. Add an Audio Chronicle link only when its article title appears in the source ad.
6. Add and save an OpenAI API key, then click **Generate localized ads**.

Output files are written into a `Localized ads` folder beside the source images. Existing outputs are not regenerated. English CAD, AUD, and GBP variants are skipped when the source contains no price, savings, percentage, or currency-specific claim.

## Reusable profile library

Select the root `image generation` folder in the app. Pixel discovers JSON profiles and reference images from this structure:

```text
image generation/
├── models/
│   └── Musicians/
│       └── Example Model/
│           ├── model.json
│           └── thumbnail.jpg
├── styles/
│   └── Documentary/
│       └── All/
│           └── style.json
├── products/
│   └── Example Product/
│       ├── product.json
│       └── reference.png
├── ad angles/
│   └── Product close-up/
│       ├── angle_prompt.json
│       └── reference.jpg
├── promotional contexts/
│   └── Holiday offer/
│       └── promo.json
├── compositions/
│   └── Tight crop/
│       └── composition.json
├── locations/
│   └── Rehearsal room/
│       └── location.json
└── looks/
    └── Documentary film/
        └── look.json
```

Each JSON file must contain valid JSON. Its schema is intentionally open-ended because Pixel appends it to the generation prompt. A minimal profile can be as simple as:

```json
{
  "lighting": "soft window light",
  "camera": "eye level",
  "avoid": ["text", "watermarks"]
}
```

Model folders also need a preview image. Product, ad-angle, and promotional-context folders may contain reference images in PNG, JPEG, HEIC, WebP, or TIFF format. Folders whose names start with `_` are ignored.

Profiles can also be created and edited from Pixel's **Manage models** and **Manage styles** screens.

## Data and security

- The repository and its Git history contain no API keys, access tokens, Shopify credentials, customer data, generated images, or private JSON profile libraries.
- OpenAI and Gemini keys are stored in macOS Keychain. Older local builds that stored an OpenAI key in app preferences are migrated to Keychain automatically.
- Prompts and selected reference images are sent directly to the chosen image provider. Review that provider's terms and data controls before sending confidential material.
- Generated images, job history, bookmarks, and cached profile metadata stay in the current user's Application Support and preferences folders unless the user exports or syncs them.
- The app has no analytics SDK and no third-party package dependencies.
- Regular generation connects only to the selected provider's API. Soundbrenner ad localization also reads public Audio Chronicle truth data and can use optional Shopify Admin credentials already present in the local user's Keychain. Those credentials are never bundled with the app.

Do not add credentials to source files, test fixtures, JSON profiles committed to Git, Xcode build settings, or screenshots. Revoke a credential immediately if it is committed, even if the commit is later deleted.

## Test

```sh
swift test
```

To verify the Xcode project builds:

```sh
xcodebuild \
  -project "Soundbrenner Pixel.xcodeproj" \
  -scheme "Soundbrenner Pixel" \
  -destination "platform=macOS" \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## License and trademarks

The source code is available under the [MIT License](LICENSE).

Soundbrenner and associated names and logos are trademarks of Soundbrenner. The MIT License does not grant permission to use those trademarks or imply endorsement by Soundbrenner.
