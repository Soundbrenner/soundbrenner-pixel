import Foundation

enum GeneratorMode: String, CaseIterable, Codable, Identifiable {
    case regular
    case adLocalization

    var id: String { rawValue }

    var title: String {
        switch self {
        case .regular:
            "Regular"
        case .adLocalization:
            "Ad localization"
        }
    }
}

enum ImageQuality: String, CaseIterable, Codable, Identifiable {
    case auto
    case low
    case medium
    case high

    var id: String { rawValue }

    var title: String {
        rawValue.capitalized
    }

    var pricingHint: String {
        switch self {
        case .auto:
            "pricing varies"
        case .low:
            "baseline"
        case .medium:
            "~3.8x low"
        case .high:
            "~14.8x low"
        }
    }

    var titleWithPricingHint: String {
        "\(title) (\(pricingHint))"
    }
}

enum OutputFormat: String, CaseIterable, Codable, Identifiable {
    case png
    case jpeg
    case webp

    var id: String { rawValue }

    var title: String {
        rawValue.uppercased()
    }
}

enum ModerationLevel: String, CaseIterable, Codable, Identifiable {
    case auto
    case low

    var id: String { rawValue }

    var title: String {
        rawValue.capitalized
    }
}

enum ResolutionPreset: String, CaseIterable, Codable, Identifiable {
    case square1k
    case portrait1k
    case landscape1k
    case square2k
    case landscape2k
    case landscape4k
    case portrait4k

    var id: String { rawValue }

    var sizeValue: String {
        switch self {
        case .square1k: "1024x1024"
        case .portrait1k: "1024x1536"
        case .landscape1k: "1536x1024"
        case .square2k: "2048x2048"
        case .landscape2k: "2048x1152"
        case .landscape4k: "3840x2160"
        case .portrait4k: "2160x3840"
        }
    }

    var title: String {
        switch self {
        case .square1k: "1K Square"
        case .portrait1k: "1K Portrait"
        case .landscape1k: "1K Landscape"
        case .square2k: "2K Square"
        case .landscape2k: "2K Landscape"
        case .landscape4k: "4K Landscape"
        case .portrait4k: "4K Portrait"
        }
    }

    var subtitle: String {
        sizeValue
    }

    var relativeCostMultiplier: Double {
        switch self {
        case .square1k:
            1.0
        case .portrait1k, .landscape1k:
            1.5
        case .square2k:
            4.0
        case .landscape2k:
            2.25
        case .landscape4k, .portrait4k:
            7.9
        }
    }

    var pricingHint: String {
        if relativeCostMultiplier == 1.0 {
            return "baseline"
        }
        return "~\(relativeCostMultiplier.formatted(.number.precision(.fractionLength(0...1))))x 1K square"
    }

    var titleWithPricingHint: String {
        "\(title) (\(pricingHint))"
    }

    var geminiAspectRatio: String {
        switch self {
        case .square1k, .square2k:
            "1:1"
        case .portrait1k:
            "2:3"
        case .landscape1k:
            "3:2"
        case .landscape2k, .landscape4k:
            "16:9"
        case .portrait4k:
            "9:16"
        }
    }

    var geminiImageSize: String {
        switch self {
        case .square1k, .portrait1k, .landscape1k:
            "1K"
        case .square2k, .landscape2k:
            "2K"
        case .landscape4k, .portrait4k:
            "4K"
        }
    }
}

enum GeminiAspectRatio: String, CaseIterable, Codable, Identifiable {
    case square = "1:1"
    case portraitTwoByThree = "2:3"
    case landscapeThreeByTwo = "3:2"
    case portraitThreeByFour = "3:4"
    case landscapeFourByThree = "4:3"
    case portraitFourByFive = "4:5"
    case landscapeFiveByFour = "5:4"
    case portraitNineBySixteen = "9:16"
    case landscapeSixteenByNine = "16:9"
    case ultrawideTwentyOneByNine = "21:9"

    var id: String { rawValue }
    var title: String { rawValue }
}

enum GeminiImageSize: String, CaseIterable, Codable, Identifiable {
    case oneK = "1K"
    case twoK = "2K"
    case fourK = "4K"

    var id: String { rawValue }
    var title: String { rawValue }
}

struct GenerationForm: Codable, Equatable {
    var prompt = ""
    var cameraJSON = ""
    var shotMode: ShotMode = .withModel
    var audience: AudienceKind = .musicians
    var imageModel = "gpt-image-2"
    var quality: ImageQuality = .high
    var resolution: ResolutionPreset = .landscape2k
    var geminiAspectRatio: GeminiAspectRatio = .landscapeSixteenByNine
    var geminiImageSize: GeminiImageSize = .twoK
    var imageCount = 1
    var outputFormat: OutputFormat = .png
    var outputCompression = 90
    var moderation: ModerationLevel = .auto

    var sanitizedImageCount: Int {
        min(max(imageCount, 1), 8)
    }

    enum CodingKeys: String, CodingKey {
        case prompt
        case cameraJSON
        case shotMode
        case audience
        case imageModel
        case quality
        case resolution
        case geminiAspectRatio
        case geminiImageSize
        case imageCount
        case outputFormat
        case outputCompression
        case moderation
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        cameraJSON = try container.decodeIfPresent(String.self, forKey: .cameraJSON) ?? ""
        shotMode = try container.decodeIfPresent(ShotMode.self, forKey: .shotMode) ?? .withModel
        audience = try container.decodeIfPresent(AudienceKind.self, forKey: .audience) ?? .musicians
        imageModel = try container.decodeIfPresent(String.self, forKey: .imageModel) ?? "gpt-image-2"
        quality = try container.decodeIfPresent(ImageQuality.self, forKey: .quality) ?? .high
        resolution = try container.decodeIfPresent(ResolutionPreset.self, forKey: .resolution) ?? .landscape2k
        geminiAspectRatio = try container.decodeIfPresent(GeminiAspectRatio.self, forKey: .geminiAspectRatio)
            ?? GeminiAspectRatio(rawValue: resolution.geminiAspectRatio)
            ?? .landscapeSixteenByNine
        geminiImageSize = try container.decodeIfPresent(GeminiImageSize.self, forKey: .geminiImageSize)
            ?? GeminiImageSize(rawValue: resolution.geminiImageSize)
            ?? .twoK
        imageCount = try container.decodeIfPresent(Int.self, forKey: .imageCount) ?? 1
        outputFormat = try container.decodeIfPresent(OutputFormat.self, forKey: .outputFormat) ?? .png
        outputCompression = try container.decodeIfPresent(Int.self, forKey: .outputCompression) ?? 90
        moderation = try container.decodeIfPresent(ModerationLevel.self, forKey: .moderation) ?? .auto
    }
}

enum ShotMode: String, CaseIterable, Codable, Identifiable {
    case withModel
    case inContext
    case productOnWhite
    case plain

    var id: String { rawValue }

    var title: String {
        switch self {
        case .withModel:
            "With model"
        case .inContext:
            "In context"
        case .productOnWhite:
            "Product on white"
        case .plain:
            "Plain"
        }
    }

    var subtitle: String {
        switch self {
        case .withModel:
            "Use people, model JSON, model crops, and lifestyle scenes."
        case .inContext:
            "No model JSON. Use contextual product scenes and product references."
        case .productOnWhite:
            "No model JSON. Clean white-background product shot."
        case .plain:
            "No saved JSON layers. Use only your prompt and reference photos."
        }
    }

    var allowsModelSelection: Bool {
        self == .withModel
    }

    var usesAudienceSelection: Bool {
        self == .withModel || self == .inContext
    }

    var presetFolderName: String {
        switch self {
        case .withModel:
            "with model"
        case .inContext:
            "in context"
        case .productOnWhite:
            "product on white"
        case .plain:
            "plain"
        }
    }
}

enum AudienceKind: String, CaseIterable, Codable, Identifiable, Hashable {
    case musicians
    case gamers
    case worshipMusicians
    case motorcyclists

    var id: String { rawValue }

    var title: String {
        switch self {
        case .musicians:
            "Musicians"
        case .gamers:
            "Gamers"
        case .worshipMusicians:
            "Worship musicians"
        case .motorcyclists:
            "Motorcyclists"
        }
    }

    var folderName: String {
        switch self {
        case .musicians:
            "Musicians"
        case .gamers:
            "Gamers"
        case .worshipMusicians:
            "Worship"
        case .motorcyclists:
            "Motorcyclists"
        }
    }

    var randomModelMode: RandomModelMode {
        switch self {
        case .musicians:
            .musicians
        case .gamers:
            .gamers
        case .worshipMusicians:
            .worshipMusicians
        case .motorcyclists:
            .motorcyclists
        }
    }
}

struct PromptModelProfile: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var storageFolderName: String
    var thumbnailFileName: String
    var promptJSON: String

    init(id: UUID = UUID(), name: String, storageFolderName: String, thumbnailFileName: String, promptJSON: String) {
        self.id = id
        self.name = name
        self.storageFolderName = storageFolderName
        self.thumbnailFileName = thumbnailFileName
        self.promptJSON = promptJSON
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case storageFolderName
        case thumbnailFileName
        case promptJSON
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        storageFolderName = try container.decodeIfPresent(String.self, forKey: .storageFolderName) ?? name
        thumbnailFileName = try container.decode(String.self, forKey: .thumbnailFileName)
        promptJSON = try container.decode(String.self, forKey: .promptJSON)
    }
}

struct CameraProfile: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var storageFolderName: String
    var promptJSON: String

    init(id: UUID = UUID(), name: String, storageFolderName: String, promptJSON: String) {
        self.id = id
        self.name = name
        self.storageFolderName = storageFolderName
        self.promptJSON = promptJSON
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case storageFolderName
        case promptJSON
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        storageFolderName = try container.decodeIfPresent(String.self, forKey: .storageFolderName) ?? name
        promptJSON = try container.decode(String.self, forKey: .promptJSON)
    }
}

enum StyleUsageCategory: String, CaseIterable, Identifiable {
    case withModel
    case inContext

    var id: String { rawValue }

    var title: String {
        switch self {
        case .withModel:
            "With model"
        case .inContext:
            "In context"
        }
    }

    var subtitle: String {
        switch self {
        case .withModel:
            "Keeps selected model JSON active."
        case .inContext:
            "Suppresses selected model JSON."
        }
    }
}

struct ProductReferenceProfile: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let collectionName: String?
    let productName: String
    let variantName: String?
    let shotMode: ShotMode?
    let directoryURL: URL
    let promptJSON: String?
    let referenceImageURLs: [URL]

    var normalizedPromptJSON: String {
        promptJSON?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func applies(to shotMode: ShotMode) -> Bool {
        guard shotMode != .plain else {
            return false
        }

        guard let productShotMode = self.shotMode else {
            return true
        }
        if shotMode == .productOnWhite && productShotMode == .inContext {
            return true
        }
        return productShotMode == shotMode
    }
}

struct AdAngleProfile: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let directoryURL: URL
    let promptJSON: String
    let referenceImageURLs: [URL]

    var normalizedPromptJSON: String {
        promptJSON.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct PromotionalContextProfile: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let directoryURL: URL
    let promptJSON: String
    let referenceImageURLs: [URL]

    var normalizedPromptJSON: String {
        promptJSON.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct GeneratedImagePayload {
    let data: Data
    let format: OutputFormat
}

enum AdLocalizationLanguage: String, CaseIterable, Codable, Identifiable, Hashable {
    case englishUSD
    case englishGBP
    case englishAUD
    case englishCAD
    case germanEUR
    case frenchEUR
    case spanishEUR
    case italianEUR
    case japaneseJPY
    case koreanKRW

    static let allCases: [AdLocalizationLanguage] = [
        .englishGBP,
        .englishAUD,
        .englishCAD,
        .germanEUR,
        .frenchEUR,
        .spanishEUR,
        .italianEUR,
        .japaneseJPY,
        .koreanKRW
    ]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .englishUSD: "English + USD"
        case .englishGBP: "English + GBP"
        case .englishAUD: "English + AUD"
        case .englishCAD: "English + CAD"
        case .germanEUR: "German + EUR"
        case .frenchEUR: "French + EUR"
        case .spanishEUR: "Spanish + EUR"
        case .italianEUR: "Italian + EUR"
        case .japaneseJPY: "Japanese + JPY"
        case .koreanKRW: "Korean + KRW"
        }
    }

    var localeName: String {
        switch self {
        case .englishUSD: "English for the United States"
        case .englishGBP: "English for the United Kingdom"
        case .englishAUD: "English for Australia"
        case .englishCAD: "English for Canada"
        case .germanEUR: "German for Germany"
        case .frenchEUR: "French for France"
        case .spanishEUR: "Spanish for Spain"
        case .italianEUR: "Italian for Italy"
        case .japaneseJPY: "Japanese for Japan"
        case .koreanKRW: "Korean for South Korea"
        }
    }

    var outputCode: String {
        switch self {
        case .englishUSD: "en-US"
        case .englishGBP: "en-GB"
        case .englishAUD: "en-AU"
        case .englishCAD: "en-CA"
        case .germanEUR: "de-EUR"
        case .frenchEUR: "fr-EUR"
        case .spanishEUR: "es-EUR"
        case .italianEUR: "it-EUR"
        case .japaneseJPY: "ja-JP"
        case .koreanKRW: "ko-KR"
        }
    }

    var languageCode: String {
        switch self {
        case .englishUSD, .englishGBP, .englishAUD, .englishCAD: "en"
        case .germanEUR: "de"
        case .frenchEUR: "fr"
        case .spanishEUR: "es"
        case .italianEUR: "it"
        case .japaneseJPY: "ja"
        case .koreanKRW: "ko"
        }
    }

    var countryCode: String {
        switch self {
        case .englishUSD: "US"
        case .englishGBP: "GB"
        case .englishAUD: "AU"
        case .englishCAD: "CA"
        case .germanEUR, .frenchEUR, .spanishEUR, .italianEUR: "DE"
        case .japaneseJPY: "JP"
        case .koreanKRW: "KR"
        }
    }

    var marketCode: String {
        switch self {
        case .englishUSD: "US"
        case .englishGBP: "GB"
        case .englishAUD: "AU"
        case .englishCAD: "CA"
        case .germanEUR, .frenchEUR, .spanishEUR, .italianEUR: "EU"
        case .japaneseJPY: "JP"
        case .koreanKRW: "KR"
        }
    }

    var currencyCode: String {
        switch self {
        case .englishUSD: "USD"
        case .englishGBP: "GBP"
        case .englishAUD: "AUD"
        case .englishCAD: "CAD"
        case .germanEUR, .frenchEUR, .spanishEUR, .italianEUR: "EUR"
        case .japaneseJPY: "JPY"
        case .koreanKRW: "KRW"
        }
    }

    var localeIdentifier: String {
        switch self {
        case .englishUSD: "en_US"
        case .englishGBP: "en_GB"
        case .englishAUD: "en_AU"
        case .englishCAD: "en_CA"
        case .germanEUR: "de_DE"
        case .frenchEUR: "fr_FR"
        case .spanishEUR: "es_ES"
        case .italianEUR: "it_IT"
        case .japaneseJPY: "ja_JP"
        case .koreanKRW: "ko_KR"
        }
    }

    var phraseGuidance: String {
        switch self {
        case .germanEUR:
            """
            German brand voice:
            - Use informal consumer-brand German: du, dein, dir. Never use Sie, Ihnen, Ihr, or formal business German.
            - Write like a modern consumer electronics brand on Instagram/Facebook: simple, confident, direct, and natural.
            - Prefer concise ad phrasing such as "Spare jetzt", "Nur kurze Zeit", and "Wieder da" when it fits the source layout.

            If these common ad phrases are present, localize them exactly:
            - "CRAZY SUMMER DEAL" -> "IRRER SOMMERDEAL"
            - "SUMMER SALE" -> "SOMMERANGEBOT"
            - "SPECIAL OFFER" -> "SONDERANGEBOT"
            - "FINAL HOURS" -> "LETZTE STUNDEN"
            - "BACK IN STOCK" -> "WIEDER AUF LAGER"
            - "{percent}% OFF SITE WIDE" -> "{percent}% RABATT AUF ALLES"
            - "LIMITED TIME!" -> "NUR KURZE ZEIT!"
            - "LAST CHANCE!!" -> "LETZTE CHANCE!!"
            - "Decline" -> "Ablehnen"
            - "Accept" -> "Annehmen"
            """
        case .englishUSD, .englishGBP, .englishAUD, .englishCAD:
            """
            English brand voice:
            - Keep concise native English in a modern consumer electronics tone.
            - Think Apple-like advertising: clear, confident, simple, never shouty or literal.
            - Adapt currency, prices, shipping wording, and region-specific offer phrasing to \(localeName).
            - If the target is Canada, Australia, or the UK, this is not a copy-through English run: replace USD source amounts with the exact target-market amount and currency display from the truth packet.
            - Do not make the copy sound like a translation.
            """
        case .frenchEUR:
            """
            French brand voice:
            - Use concise, natural consumer-brand French for Meta ads, not stiff corporate French.
            - Prefer clear, polished, Apple-like phrasing over literal translation.
            - Keep urgency and offers short enough to fit the original layout.
            - Preserve brand names, product names, URLs, promo codes, trademarks, and exact price facts.

            If these common ad phrases are present, localize them with the live percent from the truth packet:
            - "{percent}% OFF" -> "-{percent} %"
            - "UP TO {percent}% OFF" -> "JUSQU'A -{percent} %"
            - "{percent}% OFF SITE WIDE" -> "-{percent} % SUR TOUT LE SITE"
            """
        case .spanishEUR:
            """
            Spanish brand voice:
            - Use natural European Spanish for Spain.
            - Use tú/tu, not usted/su, unless the source is clearly formal.
            - Keep the tone direct, polished, and consumer-brand friendly.
            - Preserve brand names, product names, URLs, promo codes, trademarks, and exact price facts.

            If these common ad phrases are present, localize them with the live percent from the truth packet:
            - "{percent}% OFF" -> "{percent}% DTO."
            - "UP TO {percent}% OFF" -> "HASTA {percent}% DTO."
            - "{percent}% OFF SITE WIDE" -> "{percent}% DTO. EN TODO"
            """
        case .italianEUR:
            """
            Italian brand voice:
            - Use natural consumer-brand Italian.
            - Use tu/tuo, not Lei/Suo.
            - Keep copy short, confident, and made for Instagram/Facebook, not literal.
            - Preserve brand names, product names, URLs, promo codes, trademarks, and exact price facts.

            If these common ad phrases are present, localize them with the live percent from the truth packet:
            - "{percent}% OFF" -> "{percent}% DI SCONTO"
            - "UP TO {percent}% OFF" -> "FINO AL {percent}% DI SCONTO"
            - "{percent}% OFF SITE WIDE" -> "{percent}% DI SCONTO SU TUTTO"
            """
        case .japaneseJPY:
            """
            Japanese brand voice:
            - Use polished, concise consumer-ad Japanese.
            - Avoid stiff corporate or overly formal business Japanese.
            - Keep urgency natural and compact; preserve layout fit over literal wording.
            - Keep Soundbrenner and Wave Pro product names in Latin characters when that reads best.
            - Preserve URLs, promo codes, trademarks, and exact price facts.

            If these common ad phrases are present, localize them with the live percent from the truth packet:
            - "{percent}% OFF" -> "{percent}%オフ"
            - "UP TO {percent}% OFF" -> "最大{percent}%オフ"
            - "{percent}% OFF SITE WIDE" -> "全品{percent}%オフ"
            - "SITE WIDE" -> "全品対象"
            """
        case .koreanKRW:
            """
            Korean brand voice:
            - Use polished, concise consumer-brand Korean for Meta ads.
            - Avoid stiff corporate phrasing and literal English structure.
            - Keep urgency natural and compact; preserve layout fit over literal wording.
            - Preserve brand names, product names, URLs, promo codes, trademarks, and exact price facts.

            If these common ad phrases are present, localize them with the live percent from the truth packet:
            - "{percent}% OFF" -> "{percent}% 할인"
            - "UP TO {percent}% OFF" -> "최대 {percent}% 할인"
            - "{percent}% OFF SITE WIDE" -> "전 상품 {percent}% 할인"
            """
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        switch rawValue {
        case "german": self = .germanEUR
        case "french": self = .frenchEUR
        case "spanish": self = .spanishEUR
        case "italian": self = .italianEUR
        case "japanese": self = .japaneseJPY
        case "korean": self = .koreanKRW
        default:
            guard let value = Self(rawValue: rawValue) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unknown ad localization market: \(rawValue)"
                )
            }
            self = value
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum AdLocalizationProduct: String, CaseIterable, Codable, Identifiable, Hashable {
    case none
    case wave
    case wavePro
    case spark
    case pulse

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "None"
        case .wave: "Wave"
        case .wavePro: "Wave Pro"
        case .spark: "Spark"
        case .pulse: "Pulse"
        }
    }

    var productName: String {
        switch self {
        case .none: "None"
        case .wave: "Soundbrenner Wave"
        case .wavePro: "Soundbrenner Wave Pro"
        case .spark: "Soundbrenner Spark"
        case .pulse: "Soundbrenner Pulse"
        }
    }

    var productID: String {
        switch self {
        case .none: ""
        case .wave: "soundbrenner-wave-in-ear-monitors"
        case .wavePro: "soundbrenner-wave-pro-in-ear-monitors"
        case .spark: "soundbrenner-spark-music-practice-companion"
        case .pulse: "soundbrenner-pulse-vibrating-metronome"
        }
    }

    var shopifyProductID: String {
        switch self {
        case .none: ""
        case .wave: "8222899831035"
        case .wavePro: "9187329835259"
        case .spark: "8634635288827"
        case .pulse: "7972747903227"
        }
    }
}

enum AdLocalizationJobStatus: String, Codable, Hashable {
    case queued
    case running
    case succeeded
    case skipped
    case failed

    var title: String {
        switch self {
        case .queued: "Queued"
        case .running: "Running"
        case .succeeded: "Done"
        case .skipped: "Skipped"
        case .failed: "Failed"
        }
    }
}

struct AdLocalizationJob: Identifiable, Codable, Hashable {
    let id: UUID
    let sourceFileName: String
    let sourcePath: String
    let language: AdLocalizationLanguage
    var status: AdLocalizationJobStatus
    var attemptCount: Int
    var outputPath: String?
    var errorMessage: String?
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        sourceURL: URL,
        language: AdLocalizationLanguage,
        status: AdLocalizationJobStatus = .queued,
        attemptCount: Int = 0,
        outputPath: String? = nil,
        errorMessage: String? = nil,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.sourceFileName = sourceURL.lastPathComponent
        self.sourcePath = sourceURL.path
        self.language = language
        self.status = status
        self.attemptCount = attemptCount
        self.outputPath = outputPath
        self.errorMessage = errorMessage
        self.updatedAt = updatedAt
    }
}

struct AdLocalizationFailure: Identifiable, Hashable {
    let id: String
    let sourceFileName: String
    let languageTitle: String
    let message: String
}

struct GalleryImage: Identifiable, Codable, Hashable {
    let id: UUID
    let fileName: String
    let format: OutputFormat

    init(id: UUID = UUID(), fileName: String, format: OutputFormat) {
        self.id = id
        self.fileName = fileName
        self.format = format
    }
}

struct GenerationModelSnapshot: Codable, Hashable {
    let name: String
    let thumbnailFileName: String
}

struct GenerationCameraSnapshot: Codable, Hashable {
    let name: String
}

struct GenerationPresetSnapshot: Codable, Hashable {
    let category: PromptPresetCategory
    let name: String
}

enum PromptPresetCategory: String, CaseIterable, Codable, Identifiable {
    case composition
    case setting
    // Legacy persisted values. New UI/storage writes only `.setting`.
    case scene
    case location
    case look

    static var allCases: [PromptPresetCategory] {
        [.composition, .setting, .look]
    }

    var id: String { rawValue }

    static func category(forPersistedValue rawValue: String) -> PromptPresetCategory? {
        switch rawValue {
        case PromptPresetCategory.scene.rawValue, PromptPresetCategory.location.rawValue, PromptPresetCategory.setting.rawValue:
            .setting
        default:
            PromptPresetCategory(rawValue: rawValue)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let category = Self.category(forPersistedValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown prompt preset category: \(rawValue)"
            )
        }
        self = category
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var title: String {
        switch self {
        case .composition:
            "Composition"
        case .setting, .scene, .location:
            "Location"
        case .look:
            "Look"
        }
    }

    var randomTitle: String {
        switch self {
        case .composition:
            "Random crop/angle"
        case .setting, .scene, .location:
            "Random location"
        case .look:
            "Random look"
        }
    }

    var explainer: String {
        switch self {
        case .composition:
            "Crop, angle, framing, pose, and camera distance."
        case .setting, .scene, .location:
            "Place, environment, activity, props, and product context."
        case .look:
            "Capture feel such as iPhone realism, film, studio, or editorial."
        }
    }

    var folderName: String {
        switch self {
        case .composition:
            "compositions"
        case .setting:
            "locations"
        case .scene:
            "scenes"
        case .location:
            "locations"
        case .look:
            "looks"
        }
    }

    var jsonFileName: String {
        switch self {
        case .composition:
            "composition.json"
        case .setting:
            "location.json"
        case .scene:
            "scene.json"
        case .location:
            "location.json"
        case .look:
            "look.json"
        }
    }

    var legacyJSONFileNames: [String] {
        switch self {
        case .setting:
            ["setting.json", "scene.json"]
        default:
            []
        }
    }

    func applies(to shotMode: ShotMode) -> Bool {
        guard shotMode != .plain else {
            return false
        }

        return switch (self, shotMode) {
        case (.setting, .productOnWhite), (.scene, .productOnWhite), (.location, .productOnWhite):
            false
        default:
            true
        }
    }
}

struct PromptPresetProfile: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let category: PromptPresetCategory
    let shotMode: ShotMode?
    let directoryURL: URL
    let promptJSON: String

    var normalizedPromptJSON: String {
        promptJSON.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct GenerationProductSnapshot: Codable, Hashable {
    let name: String
}

struct GenerationAdAngleSnapshot: Codable, Hashable {
    let name: String
}

struct GenerationPromotionalContextSnapshot: Codable, Hashable {
    let name: String
}

struct GenerationReferenceImageSnapshot: Codable, Hashable {
    let originalFileName: String
    let fileName: String
}

enum RandomModelMode: String, CaseIterable, Codable, Identifiable {
    case none
    case all
    case gamers
    case musicians
    case worshipMusicians
    case motorcyclists

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none:
            "No random model"
        case .all:
            "Random model"
        case .gamers:
            "Random gamer model"
        case .musicians:
            "Random musician model"
        case .worshipMusicians:
            "Random worship musician model"
        case .motorcyclists:
            "Random motorcyclist model"
        }
    }

    var subtitle: String {
        switch self {
        case .none:
            "Choose saved models manually."
        case .all:
            "Pick from all saved models."
        case .gamers:
            "Pick from gamer models only."
        case .musicians:
            "Pick from musician models only."
        case .worshipMusicians:
            "Pick from worship musician models only."
        case .motorcyclists:
            "Pick from motorcyclist models only."
        }
    }
}

struct GenerationJob: Identifiable, Codable, Hashable {
    let id: UUID
    let createdAt: Date
    let inputPrompt: String
    let prompt: String
    let shotMode: ShotMode
    let audience: AudienceKind
    let imageModel: String
    let quality: ImageQuality
    let resolution: ResolutionPreset
    let geminiAspectRatio: GeminiAspectRatio
    let geminiImageSize: GeminiImageSize
    let imageCount: Int
    let outputFormat: OutputFormat
    let moderation: ModerationLevel
    let referenceImageCount: Int
    let randomModelMode: RandomModelMode
    let randomPresetCategories: [PromptPresetCategory]
    let modelNames: [String]
    let modelSnapshots: [GenerationModelSnapshot]
    let cameraSnapshot: GenerationCameraSnapshot?
    let presetSnapshots: [GenerationPresetSnapshot]
    let productSnapshot: GenerationProductSnapshot?
    let adAngleSnapshot: GenerationAdAngleSnapshot?
    let randomAdAngle: Bool
    let promotionalContextSnapshot: GenerationPromotionalContextSnapshot?
    let promotionalContextSnapshots: [GenerationPromotionalContextSnapshot]
    let randomPromotionalContext: Bool
    let referenceImages: [GenerationReferenceImageSnapshot]
    let userReferenceImages: [GenerationReferenceImageSnapshot]
    let images: [GalleryImage]
    let failureMessage: String?

    var isFailed: Bool {
        failureMessage != nil
    }

    init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        inputPrompt: String,
        prompt: String,
        shotMode: ShotMode = .withModel,
        audience: AudienceKind = .musicians,
        imageModel: String,
        quality: ImageQuality,
        resolution: ResolutionPreset,
        geminiAspectRatio: GeminiAspectRatio? = nil,
        geminiImageSize: GeminiImageSize? = nil,
        imageCount: Int,
        outputFormat: OutputFormat,
        moderation: ModerationLevel,
        referenceImageCount: Int = 0,
        randomModelMode: RandomModelMode = .none,
        randomPresetCategories: [PromptPresetCategory] = [],
        modelNames: [String] = [],
        modelSnapshots: [GenerationModelSnapshot] = [],
        cameraSnapshot: GenerationCameraSnapshot? = nil,
        presetSnapshots: [GenerationPresetSnapshot] = [],
        productSnapshot: GenerationProductSnapshot? = nil,
        adAngleSnapshot: GenerationAdAngleSnapshot? = nil,
        randomAdAngle: Bool = false,
        promotionalContextSnapshot: GenerationPromotionalContextSnapshot? = nil,
        promotionalContextSnapshots: [GenerationPromotionalContextSnapshot] = [],
        randomPromotionalContext: Bool = false,
        referenceImages: [GenerationReferenceImageSnapshot] = [],
        userReferenceImages: [GenerationReferenceImageSnapshot] = [],
        images: [GalleryImage],
        failureMessage: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.inputPrompt = inputPrompt
        self.prompt = prompt
        self.shotMode = shotMode
        self.audience = audience
        self.imageModel = imageModel
        self.quality = quality
        self.resolution = resolution
        self.geminiAspectRatio = geminiAspectRatio
            ?? GeminiAspectRatio(rawValue: resolution.geminiAspectRatio)
            ?? .landscapeSixteenByNine
        self.geminiImageSize = geminiImageSize
            ?? GeminiImageSize(rawValue: resolution.geminiImageSize)
            ?? .twoK
        self.imageCount = imageCount
        self.outputFormat = outputFormat
        self.moderation = moderation
        self.referenceImageCount = referenceImageCount
        self.randomModelMode = randomModelMode
        self.randomPresetCategories = randomPresetCategories
        self.modelNames = modelNames
        self.modelSnapshots = modelSnapshots
        self.cameraSnapshot = cameraSnapshot
        self.presetSnapshots = presetSnapshots
        self.productSnapshot = productSnapshot
        self.adAngleSnapshot = adAngleSnapshot
        self.randomAdAngle = randomAdAngle
        self.promotionalContextSnapshots = promotionalContextSnapshots.isEmpty ? promotionalContextSnapshot.map { [$0] } ?? [] : promotionalContextSnapshots
        self.promotionalContextSnapshot = promotionalContextSnapshot ?? self.promotionalContextSnapshots.first
        self.randomPromotionalContext = randomPromotionalContext
        self.referenceImages = referenceImages
        self.userReferenceImages = userReferenceImages
        self.images = images
        self.failureMessage = failureMessage
    }

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case inputPrompt
        case prompt
        case shotMode
        case audience
        case imageModel
        case quality
        case resolution
        case geminiAspectRatio
        case geminiImageSize
        case imageCount
        case outputFormat
        case moderation
        case referenceImageCount
        case randomModelMode
        case randomPresetCategories
        case modelNames
        case modelSnapshots
        case cameraSnapshot
        case presetSnapshots
        case productSnapshot
        case adAngleSnapshot
        case randomAdAngle
        case promotionalContextSnapshot
        case promotionalContextSnapshots
        case randomPromotionalContext
        case referenceImages
        case userReferenceImages
        case images
        case failureMessage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        prompt = try container.decode(String.self, forKey: .prompt)
        inputPrompt = try container.decodeIfPresent(String.self, forKey: .inputPrompt) ?? prompt
        shotMode = try container.decodeIfPresent(ShotMode.self, forKey: .shotMode) ?? .withModel
        audience = try container.decodeIfPresent(AudienceKind.self, forKey: .audience) ?? .musicians
        imageModel = try container.decodeIfPresent(String.self, forKey: .imageModel) ?? "gpt-image-2"
        quality = try container.decode(ImageQuality.self, forKey: .quality)
        resolution = try container.decode(ResolutionPreset.self, forKey: .resolution)
        geminiAspectRatio = try container.decodeIfPresent(GeminiAspectRatio.self, forKey: .geminiAspectRatio)
            ?? GeminiAspectRatio(rawValue: resolution.geminiAspectRatio)
            ?? .landscapeSixteenByNine
        geminiImageSize = try container.decodeIfPresent(GeminiImageSize.self, forKey: .geminiImageSize)
            ?? GeminiImageSize(rawValue: resolution.geminiImageSize)
            ?? .twoK
        imageCount = try container.decode(Int.self, forKey: .imageCount)
        outputFormat = try container.decode(OutputFormat.self, forKey: .outputFormat)
        moderation = try container.decode(ModerationLevel.self, forKey: .moderation)
        referenceImageCount = try container.decodeIfPresent(Int.self, forKey: .referenceImageCount) ?? 0
        randomModelMode = try container.decodeIfPresent(RandomModelMode.self, forKey: .randomModelMode) ?? .none
        randomPresetCategories = try container.decodeIfPresent([PromptPresetCategory].self, forKey: .randomPresetCategories) ?? []
        modelNames = try container.decodeIfPresent([String].self, forKey: .modelNames) ?? []
        modelSnapshots = try container.decodeIfPresent([GenerationModelSnapshot].self, forKey: .modelSnapshots) ?? []
        cameraSnapshot = try container.decodeIfPresent(GenerationCameraSnapshot.self, forKey: .cameraSnapshot)
        presetSnapshots = try container.decodeIfPresent([GenerationPresetSnapshot].self, forKey: .presetSnapshots) ?? []
        productSnapshot = try container.decodeIfPresent(GenerationProductSnapshot.self, forKey: .productSnapshot)
        adAngleSnapshot = try container.decodeIfPresent(GenerationAdAngleSnapshot.self, forKey: .adAngleSnapshot)
        randomAdAngle = try container.decodeIfPresent(Bool.self, forKey: .randomAdAngle) ?? false
        let legacyPromotionalContextSnapshot = try container.decodeIfPresent(GenerationPromotionalContextSnapshot.self, forKey: .promotionalContextSnapshot)
        promotionalContextSnapshots = try container.decodeIfPresent([GenerationPromotionalContextSnapshot].self, forKey: .promotionalContextSnapshots) ?? legacyPromotionalContextSnapshot.map { [$0] } ?? []
        promotionalContextSnapshot = legacyPromotionalContextSnapshot ?? promotionalContextSnapshots.first
        randomPromotionalContext = try container.decodeIfPresent(Bool.self, forKey: .randomPromotionalContext) ?? false
        referenceImages = try container.decodeIfPresent([GenerationReferenceImageSnapshot].self, forKey: .referenceImages) ?? []
        userReferenceImages = try container.decodeIfPresent([GenerationReferenceImageSnapshot].self, forKey: .userReferenceImages) ?? []
        images = try container.decode([GalleryImage].self, forKey: .images)
        failureMessage = try container.decodeIfPresent(String.self, forKey: .failureMessage)
    }
}

struct PendingGenerationBatch: Identifiable, Hashable {
    let id: UUID
    let createdAt: Date
    let prompt: String
    let promptWithJSONs: String?
    let imageModel: String
    let quality: ImageQuality
    let resolution: ResolutionPreset
    let geminiAspectRatio: GeminiAspectRatio
    let geminiImageSize: GeminiImageSize
    let imageCount: Int
    let outputFormat: OutputFormat
    let shotMode: ShotMode
    let audience: AudienceKind
    let randomModelMode: RandomModelMode
    let randomPresetCategories: [PromptPresetCategory]
    let modelSnapshots: [GenerationModelSnapshot]
    let cameraSnapshot: GenerationCameraSnapshot?
    let presetSnapshots: [GenerationPresetSnapshot]
    let productSnapshot: GenerationProductSnapshot?
    let adAngleSnapshot: GenerationAdAngleSnapshot?
    let randomAdAngle: Bool
    let promotionalContextSnapshot: GenerationPromotionalContextSnapshot?
    let promotionalContextSnapshots: [GenerationPromotionalContextSnapshot]
    let randomPromotionalContext: Bool
    let referenceImages: [GenerationReferenceImageSnapshot]
    let userReferenceImages: [GenerationReferenceImageSnapshot]
    var statusMessage: String
    var detailMessage: String
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        prompt: String,
        promptWithJSONs: String? = nil,
        imageModel: String,
        quality: ImageQuality,
        resolution: ResolutionPreset,
        geminiAspectRatio: GeminiAspectRatio? = nil,
        geminiImageSize: GeminiImageSize? = nil,
        imageCount: Int,
        outputFormat: OutputFormat,
        shotMode: ShotMode = .withModel,
        audience: AudienceKind = .musicians,
        randomModelMode: RandomModelMode = .none,
        randomPresetCategories: [PromptPresetCategory] = [],
        modelSnapshots: [GenerationModelSnapshot] = [],
        cameraSnapshot: GenerationCameraSnapshot? = nil,
        presetSnapshots: [GenerationPresetSnapshot] = [],
        productSnapshot: GenerationProductSnapshot? = nil,
        adAngleSnapshot: GenerationAdAngleSnapshot? = nil,
        randomAdAngle: Bool = false,
        promotionalContextSnapshot: GenerationPromotionalContextSnapshot? = nil,
        promotionalContextSnapshots: [GenerationPromotionalContextSnapshot] = [],
        randomPromotionalContext: Bool = false,
        referenceImages: [GenerationReferenceImageSnapshot] = [],
        userReferenceImages: [GenerationReferenceImageSnapshot] = [],
        statusMessage: String = "Queued",
        detailMessage: String = "Preparing request."
    ) {
        self.id = id
        self.createdAt = createdAt
        self.prompt = prompt
        self.promptWithJSONs = promptWithJSONs
        self.imageModel = imageModel
        self.quality = quality
        self.resolution = resolution
        self.geminiAspectRatio = geminiAspectRatio
            ?? GeminiAspectRatio(rawValue: resolution.geminiAspectRatio)
            ?? .landscapeSixteenByNine
        self.geminiImageSize = geminiImageSize
            ?? GeminiImageSize(rawValue: resolution.geminiImageSize)
            ?? .twoK
        self.imageCount = imageCount
        self.outputFormat = outputFormat
        self.shotMode = shotMode
        self.audience = audience
        self.randomModelMode = randomModelMode
        self.randomPresetCategories = randomPresetCategories
        self.modelSnapshots = modelSnapshots
        self.cameraSnapshot = cameraSnapshot
        self.presetSnapshots = presetSnapshots
        self.productSnapshot = productSnapshot
        self.adAngleSnapshot = adAngleSnapshot
        self.randomAdAngle = randomAdAngle
        self.promotionalContextSnapshots = promotionalContextSnapshots.isEmpty ? promotionalContextSnapshot.map { [$0] } ?? [] : promotionalContextSnapshots
        self.promotionalContextSnapshot = promotionalContextSnapshot ?? self.promotionalContextSnapshots.first
        self.randomPromotionalContext = randomPromotionalContext
        self.referenceImages = referenceImages
        self.userReferenceImages = userReferenceImages
        self.statusMessage = statusMessage
        self.detailMessage = detailMessage
        self.updatedAt = createdAt
    }
}

struct PendingGenerationRecord: Identifiable, Codable {
    let id: UUID
    let form: GenerationForm
    let inputPrompt: String
    let referenceImageCount: Int
    let randomModelMode: RandomModelMode
    let randomPresetCategories: [PromptPresetCategory]
    let modelNames: [String]
    let modelSnapshots: [GenerationModelSnapshot]
    let cameraSnapshot: GenerationCameraSnapshot?
    let presetSnapshots: [GenerationPresetSnapshot]
    let productSnapshot: GenerationProductSnapshot?
    let adAngleSnapshot: GenerationAdAngleSnapshot?
    let randomAdAngle: Bool
    let promotionalContextSnapshot: GenerationPromotionalContextSnapshot?
    let promotionalContextSnapshots: [GenerationPromotionalContextSnapshot]
    let randomPromotionalContext: Bool
    let referenceImages: [GenerationReferenceImageSnapshot]
    let userReferenceImages: [GenerationReferenceImageSnapshot]

    init(
        id: UUID,
        form: GenerationForm,
        inputPrompt: String,
        referenceImageCount: Int,
        randomModelMode: RandomModelMode,
        randomPresetCategories: [PromptPresetCategory],
        modelNames: [String],
        modelSnapshots: [GenerationModelSnapshot],
        cameraSnapshot: GenerationCameraSnapshot?,
        presetSnapshots: [GenerationPresetSnapshot],
        productSnapshot: GenerationProductSnapshot?,
        adAngleSnapshot: GenerationAdAngleSnapshot? = nil,
        randomAdAngle: Bool = false,
        promotionalContextSnapshot: GenerationPromotionalContextSnapshot? = nil,
        promotionalContextSnapshots: [GenerationPromotionalContextSnapshot] = [],
        randomPromotionalContext: Bool = false,
        referenceImages: [GenerationReferenceImageSnapshot],
        userReferenceImages: [GenerationReferenceImageSnapshot]
    ) {
        self.id = id
        self.form = form
        self.inputPrompt = inputPrompt
        self.referenceImageCount = referenceImageCount
        self.randomModelMode = randomModelMode
        self.randomPresetCategories = randomPresetCategories
        self.modelNames = modelNames
        self.modelSnapshots = modelSnapshots
        self.cameraSnapshot = cameraSnapshot
        self.presetSnapshots = presetSnapshots
        self.productSnapshot = productSnapshot
        self.adAngleSnapshot = adAngleSnapshot
        self.randomAdAngle = randomAdAngle
        self.promotionalContextSnapshots = promotionalContextSnapshots.isEmpty ? promotionalContextSnapshot.map { [$0] } ?? [] : promotionalContextSnapshots
        self.promotionalContextSnapshot = promotionalContextSnapshot ?? self.promotionalContextSnapshots.first
        self.randomPromotionalContext = randomPromotionalContext
        self.referenceImages = referenceImages
        self.userReferenceImages = userReferenceImages
    }

    enum CodingKeys: String, CodingKey {
        case id
        case form
        case inputPrompt
        case referenceImageCount
        case randomModelMode
        case randomPresetCategories
        case modelNames
        case modelSnapshots
        case cameraSnapshot
        case presetSnapshots
        case productSnapshot
        case adAngleSnapshot
        case randomAdAngle
        case promotionalContextSnapshot
        case promotionalContextSnapshots
        case randomPromotionalContext
        case referenceImages
        case userReferenceImages
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        form = try container.decode(GenerationForm.self, forKey: .form)
        inputPrompt = try container.decode(String.self, forKey: .inputPrompt)
        referenceImageCount = try container.decode(Int.self, forKey: .referenceImageCount)
        randomModelMode = try container.decodeIfPresent(RandomModelMode.self, forKey: .randomModelMode) ?? .none
        randomPresetCategories = try container.decodeIfPresent([PromptPresetCategory].self, forKey: .randomPresetCategories) ?? []
        modelNames = try container.decodeIfPresent([String].self, forKey: .modelNames) ?? []
        modelSnapshots = try container.decodeIfPresent([GenerationModelSnapshot].self, forKey: .modelSnapshots) ?? []
        cameraSnapshot = try container.decodeIfPresent(GenerationCameraSnapshot.self, forKey: .cameraSnapshot)
        presetSnapshots = try container.decodeIfPresent([GenerationPresetSnapshot].self, forKey: .presetSnapshots) ?? []
        productSnapshot = try container.decodeIfPresent(GenerationProductSnapshot.self, forKey: .productSnapshot)
        adAngleSnapshot = try container.decodeIfPresent(GenerationAdAngleSnapshot.self, forKey: .adAngleSnapshot)
        randomAdAngle = try container.decodeIfPresent(Bool.self, forKey: .randomAdAngle) ?? false
        let legacyPromotionalContextSnapshot = try container.decodeIfPresent(GenerationPromotionalContextSnapshot.self, forKey: .promotionalContextSnapshot)
        promotionalContextSnapshots = try container.decodeIfPresent([GenerationPromotionalContextSnapshot].self, forKey: .promotionalContextSnapshots) ?? legacyPromotionalContextSnapshot.map { [$0] } ?? []
        promotionalContextSnapshot = legacyPromotionalContextSnapshot ?? promotionalContextSnapshots.first
        randomPromotionalContext = try container.decodeIfPresent(Bool.self, forKey: .randomPromotionalContext) ?? false
        referenceImages = try container.decodeIfPresent([GenerationReferenceImageSnapshot].self, forKey: .referenceImages) ?? []
        userReferenceImages = try container.decodeIfPresent([GenerationReferenceImageSnapshot].self, forKey: .userReferenceImages) ?? []
    }
}

struct OpenAIImageGenerationRequest: Encodable {
    let model: String
    let prompt: String
    let size: String
    let quality: String
    let n: Int
    let outputFormat: String
    let outputCompression: Int?
    let moderation: String

    enum CodingKeys: String, CodingKey {
        case model
        case prompt
        case size
        case quality
        case n
        case outputFormat = "output_format"
        case outputCompression = "output_compression"
        case moderation
    }
}

struct OpenAIImageGenerationResponse: Decodable {
    let data: [OpenAIImageDatum]
}

struct OpenAIImageDatum: Decodable {
    let b64JSON: String

    enum CodingKeys: String, CodingKey {
        case b64JSON = "b64_json"
    }
}

extension GenerationForm {
    var requestBody: OpenAIImageGenerationRequest {
        OpenAIImageGenerationRequest(
            model: imageModel,
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            size: resolution.sizeValue,
            quality: quality.rawValue,
            n: sanitizedImageCount,
            outputFormat: outputFormat.rawValue,
            outputCompression: outputFormat == .png ? nil : outputCompression,
            moderation: moderation.rawValue
        )
    }
}

extension PromptModelProfile {
    private static let gamerThumbnailID = "2CF831F0-8B3D-474F-BA98-DC976EF5A2B7"

    var normalizedPromptJSON: String {
        promptJSON.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var audienceKind: AudienceKind {
        let searchableText = "\(name)\n\(storageFolderName)\n\(thumbnailFileName)\n\(promptJSON)".lowercased()

        if searchableText.contains("motorcyclist")
            || searchableText.contains("motorcycle")
            || searchableText.contains("moto ")
            || searchableText.contains("rider")
            || searchableText.contains("helmet") {
            return .motorcyclists
        }

        if searchableText.contains("worship")
            || searchableText.contains("church")
            || searchableText.contains("sanctuary")
            || searchableText.contains("keyboardist worship")
            || searchableText.contains("praise team") {
            return .worshipMusicians
        }

        if isGamerModel {
            return .gamers
        }

        return .musicians
    }

    var isGamerModel: Bool {
        name.localizedCaseInsensitiveContains("gamer")
            || thumbnailFileName.localizedCaseInsensitiveContains(Self.gamerThumbnailID)
            || storageFolderName.localizedCaseInsensitiveContains("gamer")
    }
}

extension RandomModelMode {
    var audienceKind: AudienceKind? {
        switch self {
        case .none, .all:
            nil
        case .gamers:
            .gamers
        case .musicians:
            .musicians
        case .worshipMusicians:
            .worshipMusicians
        case .motorcyclists:
            .motorcyclists
        }
    }

    func includes(_ profile: PromptModelProfile) -> Bool {
        switch self {
        case .none:
            false
        case .all:
            true
        case .gamers, .musicians, .worshipMusicians, .motorcyclists:
            profile.audienceKind == audienceKind
        }
    }
}

extension AudienceKind {
    func includes(_ profile: PromptModelProfile) -> Bool {
        profile.audienceKind == self
    }
}

extension PromptPresetProfile {
    func applies(to audience: AudienceKind, in shotMode: ShotMode) -> Bool {
        guard shotMode.usesAudienceSelection else {
            return inferredAudience == nil
        }

        guard let inferredAudience else {
            return true
        }

        return inferredAudience == audience
    }

    var inferredAudience: AudienceKind? {
        guard category == .setting else {
            return nil
        }

        let searchableText = "\(name)\n\(directoryURL.path)\n\(promptJSON)".lowercased()
        let gamerSignals = [
            "gamer", "gaming", "pc", "playstation", "console", "controller",
            "battlestation", "keyboard", "mouse", "esports"
        ]
        let worshipSignals = [
            "worship", "church", "sanctuary", "praise team", "service", "sermon",
            "drum shield", "stage piano", "worship leader", "soundcheck"
        ]
        let motorcyclistSignals = [
            "motorcycle", "motorcyclist", "moto", "rider", "helmet", "garage",
            "roadside", "touring", "commute", "bike", "pre-ride"
        ]
        let musicianSignals = [
            "musician", "music", "drum", "guitar", "piano",
            "rehearsal", "instrument", "song"
        ]

        if motorcyclistSignals.contains(where: searchableText.contains) {
            return .motorcyclists
        }

        if worshipSignals.contains(where: searchableText.contains) {
            return .worshipMusicians
        }

        if gamerSignals.contains(where: searchableText.contains) {
            return .gamers
        }

        if musicianSignals.contains(where: searchableText.contains) {
            return .musicians
        }

        return nil
    }
}

extension CameraProfile {
    var inferredAudience: AudienceKind? {
        let pathComponents = storageFolderName
            .split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

        guard !pathComponents.isEmpty else {
            return nil
        }

        if pathComponents.contains("all") {
            return nil
        }

        if let audience = AudienceKind.allCases.first(where: { audience in
            pathComponents.contains(audience.folderName.lowercased())
        }) {
            return audience
        }

        return nil
    }

    var audienceLabel: String {
        inferredAudience?.title ?? "All"
    }
}

extension CameraProfile {
    var normalizedPromptJSON: String {
        promptJSON.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var usageCategory: StyleUsageCategory {
        let searchableText = "\(name)\n\(promptJSON)".lowercased()
        let noModelSignals = [
            "\"people\": \"no model",
            "\"people\":\"no model",
            "no model, no human body parts",
            "product-only",
            "product only",
            "product in context",
            "3d render product in context",
            "without model"
        ]

        if noModelSignals.contains(where: searchableText.contains) || name.lowercased().hasPrefix("product -") {
            return .inContext
        }

        return .withModel
    }

    var allowsModelSelection: Bool {
        usageCategory == .withModel
    }
}

struct ImageModelOption: Identifiable, Hashable {
    let id: String
    let isSnapshot: Bool

    init(id: String) {
        self.id = id
        self.isSnapshot = id.range(of: #"gpt-image-[\d.]+-\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil
    }

    var title: String {
        if id == "gemini-3-pro-image" {
            return "Nano Banana Pro (Gemini 3 Pro Image)"
        }
        return id
    }
}

extension String {
    var isGeminiImageModel: Bool {
        hasPrefix("gemini-") && contains("image")
    }
}
