# Mediaforge

Mediaforge is a native macOS app for generating product and campaign imagery with OpenAI or Google's Gemini image API. It combines a written prompt with optional reference images and reusable JSON profiles for products, people, composition, location, and visual style.

## Requirements

- macOS 14 or newer
- Xcode with a Swift 6.3 or newer toolchain
- An [OpenAI API key](https://platform.openai.com/api-keys), a [Google AI Studio API key](https://aistudio.google.com/app/apikey), or both
- A paid API account or available API credits. Image generation is not free and costs depend on the provider, model, quality, size, and number of outputs.

No API keys, generated images, or private profile libraries are included in this repository.

## Install and run

### Xcode

1. Clone the repository:

   ```sh
   git clone https://github.com/Soundbrenner/soundbrenner-pixel.git mediaforge
   cd mediaforge
   ```

2. Open `Mediaforge.xcodeproj` in Xcode.
3. Select the **Mediaforge** scheme and **My Mac** as the destination.
4. Press **Run**.

For a local development build, code signing can remain disabled. Distribution through TestFlight or the Mac App Store requires your own Apple Developer team and signing configuration.

### Team installer and automatic updates

Open **Team/Mediaforge.dmg** in the Soundbrenner Dropbox and drag the app into Applications. If you already have Soundbrenner Pixel with Sparkle enabled, the update is offered through Check for updates… when Mediaforge ships.

The Dropbox build checks for updates automatically and shows the patchlog before installation. Choose **Mediaforge > Check for updates…** to check immediately. Updates install when you accept them.

#### Publishing a release

Keep app changes local until Florian explicitly asks to prepare a release. Deploy the release host when its routes change, before publishing a feed that references the new filenames. Release preparation submits the build to Apple for notarization.

1. Increase the marketing version and integer build number in the Xcode project. Add one to three user-facing bullets for the build in [UpdateHighlights.json](Resources/UpdateHighlights.json). Keep older entries so the updater can cover skipped releases.
2. Run `python3 scripts/release.py prepare` on a Mac with Soundbrenner's Developer ID signing identity, Xcode account, and the `soundbrenner-pixel` Sparkle key in Keychain. The script produces a signed, notarized DMG and update ZIP, plus a signed feed with the patchlog. Use `prepare --resume` to retry notarization or packaging with the same signed app. A configured `MEDIAFORGE_NOTARY_PROFILE` can use Apple’s notarytool directly.
3. Run `python3 scripts/release.py publish`. The script puts the versioned artifacts on Cloudflare R2, verifies the public downloads, switches the signed feed, and replaces the stable Dropbox installer with a checksum-verified copy. Rerun the same command if either channel needs a retry. Dropbox sync to other devices happens asynchronously.

The download host is defined in [release-host/wrangler.jsonc](release-host/wrangler.jsonc). The direct release includes Sparkle and its sandbox installer service. TestFlight and Mac App Store builds use the regular Xcode archive path.

### Swift command line

You can also build and run the Swift package directly:

```sh
swift build
swift run Mediaforge
```

The Xcode build is recommended because it uses the app's sandbox entitlements and icon configuration.

## First-time setup

Choose **Sign in with Soundbrenner** from the toolbar account menu to use company-funded OpenAI generation once the team service is configured. Use the approved account from The Metronome app. The first sign-in automatically provisions a dedicated OpenAI project and server-held service account key with a $10 USD monthly project limit. Later sessions reuse the project. Gemini still uses your own Gemini key.

### Using your own provider keys

1. Open **Connections** in the generation sidebar.
2. In **Personal API keys**, paste the key for the provider you want to use:
   - OpenAI models require an OpenAI API key.
   - Nano Banana Pro requires a Gemini API key.
3. Click the corresponding **Save ... key securely** button.
4. Optional: under **Shared JSON folder**, choose an `image generation` folder containing reusable profiles. You do not need Dropbox. Any local or synced folder works.

Both API keys are stored in macOS Keychain. They are not written to the repository or the shared profile folder.

### Team service setup

The [team service](team-service/wrangler.jsonc) uses Showtime's approved-account service binding. Before enabling team billing, provision the `OPENAI_ADMIN_KEY` and `ACCOUNT_STORAGE_KEY` Worker secrets. The OpenAI credential needs project, service-account key, and project spend-limit permissions. The storage key is a Base64-encoded random 32-byte AES key and must persist across deployments. Keep both away from desktop clients and source control. The team service checks Soundbrenner access on paid requests and sends only the Mediaforge session token to the app.

OpenAI enforces the $10 project limit based on reported API spend. Charges already in flight can arrive after the limit is reached. Personal API keys use the provider account that owns the key.

## Generate images

1. Enter a prompt.
2. Optionally add reference photos.
3. Choose an image model:
   - GPT Image 2.5 Sunburst at Max quality is the default. Flare is available when speed matters more. OpenAI models expose quality, moderation, and combined resolution presets.
   - Nano Banana Pro exposes independent aspect-ratio and output-size controls.
4. Choose the number of images and output format. JPEG and WebP also expose compression quality.
5. Choose a shot mode:
   - **With model** can use people, model profiles, product references, and all creative layers.
   - **In context** omits model profiles and uses contextual product scenes.
   - **Product on white** creates a clean product image without people or location presets.
   - **Plain** sends only your prompt and manually attached reference images.
6. Optionally select a product, ad angle, promotional context, model, composition, location, and look from the shared profile library.
7. Click **Generate images**.

Completed jobs appear in the gallery. From there you can retry failed jobs, copy their setup or prompt, reveal local files, or export images to Downloads.

## Reusable profile library

Select the root `image generation` folder in the app. Mediaforge discovers JSON profiles and reference images from this structure:

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

Each JSON file must contain valid JSON. Its schema is intentionally open-ended because Mediaforge appends it to the generation prompt. A minimal profile can be as simple as:

```json
{
  "lighting": "soft window light",
  "camera": "eye level",
  "avoid": ["text", "watermarks"]
}
```

Model folders also need a preview image. Product, ad-angle, and promotional-context folders may contain reference images in PNG, JPEG, HEIC, WebP, or TIFF format. Folders whose names start with `_` are ignored.

Profiles can also be created and edited from Mediaforge’s **Manage models** and **Manage styles** screens.

## Data and security

- The repository and its Git history contain no API keys, access tokens, Shopify credentials, customer data, generated images, or private JSON profile libraries.
- OpenAI and Gemini keys are stored in macOS Keychain. Older local builds that stored an OpenAI key in app preferences are migrated to Keychain automatically.
- Prompts and selected reference images are sent directly to the chosen image provider. Review that provider's terms and data controls before sending confidential material.
- Generated images, job history, bookmarks, and cached profile metadata stay in the current user's Application Support and preferences folders unless the user exports or syncs them.
- The app has no analytics SDK. The direct distribution build uses Sparkle for update checks and installation.
- Image generation uses the selected provider’s API.

Do not add credentials to source files, test fixtures, JSON profiles committed to Git, Xcode build settings, or screenshots. Revoke a credential immediately if it is committed, even if the commit is later deleted.

## Test

The Swift package and the standard Xcode project build from this checkout without access to a private Swift package.

```sh
swift test
```

To verify the Xcode project builds:

```sh
xcodebuild \
  -project "Mediaforge.xcodeproj" \
  -scheme "Mediaforge" \
  -destination "platform=macOS" \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## License and trademarks

The source code is available under the [MIT License](LICENSE).

Soundbrenner and associated names and logos are trademarks of Soundbrenner. The MIT License does not grant permission to use those trademarks or imply endorsement by Soundbrenner.
