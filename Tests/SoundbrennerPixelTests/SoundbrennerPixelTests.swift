import Foundation
import Testing
@testable import SoundbrennerPixel

@Test func pngRequestsOmitCompression() async throws {
    var form = GenerationForm()
    form.prompt = "A gold metronome in a brutalist studio"
    form.outputFormat = .png
    form.outputCompression = 15

    let body = form.requestBody

    #expect(body.outputCompression == nil)
    #expect(body.size == "2048x1152")
}

@Test func imageCountIsClamped() async throws {
    var form = GenerationForm()
    form.imageCount = 99

    #expect(form.requestBody.n == 8)
}

@Test func adLocalizationMarketsMatchApprovedSet() async throws {
    #expect(AdLocalizationLanguage.allCases.map(\.title) == [
        "English + GBP",
        "English + AUD",
        "English + CAD",
        "German + EUR",
        "French + EUR",
        "Spanish + EUR",
        "Italian + EUR",
        "Japanese + JPY",
        "Korean + KRW"
    ])
}

@Test func legacyGermanAdLocalizationPreferenceMigratesToGermanEUR() async throws {
    let data = try JSONEncoder().encode("german")
    let decoded = try JSONDecoder().decode(AdLocalizationLanguage.self, from: data)

    #expect(decoded == .germanEUR)
}

@Test func legacyEnglishUSDMarketIsHiddenFromSelectableOutputs() async throws {
    let data = try JSONEncoder().encode("englishUSD")
    let decoded = try JSONDecoder().decode(AdLocalizationLanguage.self, from: data)

    #expect(decoded == .englishUSD)
    #expect(!AdLocalizationLanguage.allCases.contains(.englishUSD))
}

@Test func adLocalizationProductsMatchShopifyProductSet() async throws {
    #expect(AdLocalizationProduct.allCases.map(\.title) == [
        "None",
        "Wave",
        "Wave Pro",
        "Spark",
        "Pulse"
    ])
    #expect(AdLocalizationProduct.wavePro.productID == "soundbrenner-wave-pro-in-ear-monitors")
    #expect(AdLocalizationProduct.wavePro.shopifyProductID == "9187329835259")
}

@Test func japaneseAdLocalizationGuidanceLocalizesPercentOffClaims() async throws {
    let guidance = AdLocalizationLanguage.japaneseJPY.phraseGuidance

    #expect(guidance.contains("\"{percent}% OFF\" -> \"{percent}%オフ\""))
    #expect(guidance.contains("\"UP TO {percent}% OFF\" -> \"最大{percent}%オフ\""))
    #expect(guidance.contains("\"{percent}% OFF SITE WIDE\" -> \"全品{percent}%オフ\""))
    #expect(!guidance.contains("43%"))
}

@Test func referenceLikenessSafetyRuleBlocksCopyingPeopleFromReferences() async throws {
    let rule = await AppModel.referenceLikenessSafetyRule

    #expect(rule.contains("Do not recreate, clone, or closely resemble any real person"))
    #expect(rule.contains("generate a new fictional person"))
    #expect(rule.contains("Product references may still be matched accurately"))
}

@Test func startupProfileCacheRoundTripsProfilesForMatchingStorage() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let profiles = [
        PromptModelProfile(
            name: "Marvin Cavanaugh",
            storageFolderName: "Musicians/Marvin Cavanaugh",
            thumbnailFileName: "thumbnail.png",
            promptJSON: "{\"name\":\"Marvin Cavanaugh\"}"
        )
    ]

    StartupProfileCache.save(
        profiles,
        name: "models",
        storageIdentifier: "/Dropbox/image generation/models",
        cacheDirectory: directory
    )
    let loaded: [PromptModelProfile]? = StartupProfileCache.load(
        name: "models",
        storageIdentifier: "/Dropbox/image generation/models",
        cacheDirectory: directory
    )

    #expect(loaded == profiles)
}

@Test func startupProfileCacheRejectsAChangedStorageFolder() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    StartupProfileCache.save(
        ["cached"],
        name: "models",
        storageIdentifier: "/Dropbox/old-folder",
        cacheDirectory: directory
    )
    let loaded: [String]? = StartupProfileCache.load(
        name: "models",
        storageIdentifier: "/Dropbox/new-folder",
        cacheDirectory: directory
    )

    #expect(loaded == nil)
}

@Test func promptPresetCacheRejectsANewlyAddedJSONProfile() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let cacheDirectory = directory.appendingPathComponent("cache", isDirectory: true)
    let looksDirectory = directory.appendingPathComponent("looks", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    try FileManager.default.createDirectory(at: looksDirectory, withIntermediateDirectories: true)
    let originalIdentifier = ProfileStorageFingerprint.identifier(for: [looksDirectory])

    StartupProfileCache.save(
        ["cached look"],
        name: "prompt-presets",
        storageIdentifier: originalIdentifier,
        cacheDirectory: cacheDirectory
    )

    let newLookDirectory = looksDirectory.appendingPathComponent("Analog music editorial", isDirectory: true)
    try FileManager.default.createDirectory(at: newLookDirectory, withIntermediateDirectories: true)
    try Data(#"{"capture_style":"analog music editorial"}"#.utf8)
        .write(to: newLookDirectory.appendingPathComponent("look.json"))

    let updatedIdentifier = ProfileStorageFingerprint.identifier(for: [looksDirectory])
    let loaded: [String]? = StartupProfileCache.load(
        name: "prompt-presets",
        storageIdentifier: updatedIdentifier,
        cacheDirectory: cacheDirectory
    )

    #expect(updatedIdentifier != originalIdentifier)
    #expect(loaded == nil)
}

@Test func nanoBananaProUsesGeminiProviderAndReadableTitle() {
    let option = ImageModelOption(id: GeminiImageService.nanoBananaProModel)

    #expect(option.id.isGeminiImageModel)
    #expect(option.title == "Nano Banana Pro (Gemini 3 Pro Image)")
    #expect(!"gpt-image-2".isGeminiImageModel)
}

@Test func resolutionPresetsMapToGeminiImageControls() {
    #expect(ResolutionPreset.square1k.geminiAspectRatio == "1:1")
    #expect(ResolutionPreset.square1k.geminiImageSize == "1K")
    #expect(ResolutionPreset.portrait1k.geminiAspectRatio == "2:3")
    #expect(ResolutionPreset.landscape2k.geminiAspectRatio == "16:9")
    #expect(ResolutionPreset.landscape2k.geminiImageSize == "2K")
    #expect(ResolutionPreset.portrait4k.geminiAspectRatio == "9:16")
    #expect(ResolutionPreset.portrait4k.geminiImageSize == "4K")
}

@Test func geminiSupportsEveryDocumentedAspectRatioAndImageSize() {
    #expect(GeminiAspectRatio.allCases.map(\.rawValue) == [
        "1:1",
        "2:3",
        "3:2",
        "3:4",
        "4:3",
        "4:5",
        "5:4",
        "9:16",
        "16:9",
        "21:9"
    ])
    #expect(GeminiImageSize.allCases.map(\.rawValue) == ["1K", "2K", "4K"])
}

@Test func geminiGenerationUsesSelectedImageConfigStrings() throws {
    let configuration = GeminiImageService.generationConfiguration(
        aspectRatio: .ultrawideTwentyOneByNine,
        imageSize: .fourK
    )
    let modalities = try #require(configuration["responseModalities"] as? [String])
    let imageConfig = try #require(configuration["imageConfig"] as? [String: String])

    #expect(modalities == ["IMAGE"])
    #expect(imageConfig["aspectRatio"] == "21:9")
    #expect(imageConfig["imageSize"] == "4K")
    #expect(configuration["responseFormat"] == nil)
}

@Test func legacyGenerationFormMigratesCombinedGeminiPreset() throws {
    let data = Data(#"{"resolution":"portrait4k"}"#.utf8)
    let form = try JSONDecoder().decode(GenerationForm.self, from: data)

    #expect(form.geminiAspectRatio == .portraitNineBySixteen)
    #expect(form.geminiImageSize == .fourK)
}
