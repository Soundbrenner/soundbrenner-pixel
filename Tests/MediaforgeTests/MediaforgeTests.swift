import Foundation
import Testing
@testable import Mediaforge

@Test @MainActor func galleryPreservesHistoryWhenPendingRecordsAreUnreadable() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let historyURL = directory.appendingPathComponent("jobs.json")
    let pendingURL = directory.appendingPathComponent("pending-jobs.json")
    let history = Data("""
        [{
          "id": "71E0B637-6BB0-4870-BBA4-92E6898D8C37",
          "createdAt": "2026-11-09T08:26:00Z",
          "prompt": "A musician rehearsing",
          "quality": "medium",
          "resolution": "landscape2k",
          "imageCount": 1,
          "outputFormat": "png",
          "moderation": "low",
          "images": []
        }]
        """.utf8)
    try history.write(to: historyURL)
    try Data("invalid pending records".utf8).write(to: pendingURL)
    let store = GalleryStore(baseURL: directory)

    let job = try #require(store.jobs.first)
    #expect(store.historyError != nil)
    #expect(throws: AppError.self) { try store.delete(job: job) }
    let historyAfterFailure = try Data(contentsOf: historyURL)
    #expect(historyAfterFailure == history)

    try Data("[]".utf8).write(to: pendingURL)
    store.loadHistory()
    #expect(store.historyError == nil)
    #expect(store.jobs == [job])
}

@Test @MainActor func galleryReportsUnreadableHistoryAndLoadsItOnRetry() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let historyURL = directory.appendingPathComponent("jobs.json")
    try Data("invalid history".utf8).write(to: historyURL)
    let store = GalleryStore(baseURL: directory)
    #expect(store.historyError != nil)
    #expect(throws: AppError.self) { try store.requireLoadedHistory() }

    try Data("[]".utf8).write(to: historyURL)
    store.loadHistory()
    #expect(store.historyError == nil)
    #expect(store.jobs.isEmpty)
}

@Test func promptSearchMatchesWordsIgnoringCaseAndAccents() {
    #expect(PromptSearch.matches("A guitarist in a café", query: "CAFE guitarist"))
    #expect(PromptSearch.matches("Any prompt", query: "  \n "))
    #expect(!PromptSearch.matches("A guitarist", query: "guitarist drums"))
    #expect(!PromptSearch.matches("", query: "guitar"))
}

@Test func galleryTitlesSummarizeStructuredPromptsWithoutChangingFreeText() {
    let campaign = #"{"scene_configuration":{"seasonal_customization":{"theme_name":"BFCM Sale"},"environment":{"location":"Rehearsal studio"}}}"#
    #expect(GalleryPromptTitle.text(for: campaign) == "BFCM Sale")
    #expect(GalleryPromptTitle.text(for: #"{"title":" Drum practice ","prompt":"A rehearsal"}"#) == "Drum practice")
    #expect(GalleryPromptTitle.text(for: #"{"unknown":true}"#) == "Structured prompt")
    #expect(GalleryPromptTitle.text(for: "A guitar\nin a café") == "A guitar\nin a café")
    #expect(GalleryPromptTitle.text(for: "{a handwritten prompt}") == "{a handwritten prompt}")
}

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

@Test func image25UpgradePreservesHistoricalDecodingAndGeminiChoices() throws {
    var legacy = GenerationForm()
    legacy.imageModel = "gpt-image-2"
    legacy.quality = .low
    let data = try JSONEncoder().encode(legacy)
    var restored = try JSONDecoder().decode(GenerationForm.self, from: data)
    #expect(restored.imageModel == "gpt-image-2")
    #expect(restored.quality == .low)
    restored.upgradeLegacyImageDefaults()
    #expect(restored.imageModel == "gpt-image-2.5-sunburst")
    #expect(restored.quality == .max)
    var gemini = legacy
    gemini.imageModel = GeminiImageService.nanoBananaProModel
    gemini.upgradeLegacyImageDefaults()
    #expect(gemini.imageModel == GeminiImageService.nanoBananaProModel)
    #expect(gemini.quality == .low)
}

@Test func image25QualityOptionsStayCompatibleWithOlderModels() {
    #expect(ImageQuality.supported(by: "gpt-image-2.5-sunburst").contains(.max))
    #expect(ImageQuality.supported(by: "gpt-image-2.5-flare").contains(.xhigh))
    #expect(!ImageQuality.supported(by: "gpt-image-2").contains(.max))
    #expect(ImageModelOption(id: "gpt-image-2.5-sunburst-2026-09-08").isSnapshot)
}
