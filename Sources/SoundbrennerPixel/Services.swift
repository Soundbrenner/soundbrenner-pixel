import AppKit
import CryptoKit
import Foundation
import LocalAuthentication
import Security
import OSLog
@preconcurrency import UserNotifications

private enum PreferenceKeys {
    static let cameraProfileIDMigrationKey = "camera_profile_id_migrations_v1"
}

enum AppError: LocalizedError {
    case missingAPIKey
    case missingGeminiAPIKey
    case missingPrompt
    case invalidResponse
    case invalidImageData
    case invalidCameraJSON
    case invalidModelJSON(String)
    case missingModelThumbnail(String)
    case modelRefreshFailed
    case missingAdLocalizationFolder
    case missingAdLocalizationLanguages
    case emptyAdLocalizationFolder
    case requestTimedOut
    case networkConnectionLost
    case tooManyGeminiReferenceImages(Int)
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "Add your OpenAI API key before generating images."
        case .missingGeminiAPIKey:
            "Add your Gemini API key before using Nano Banana Pro."
        case .missingPrompt:
            "Enter a prompt before generating images."
        case .invalidResponse:
            "The API response was incomplete or unreadable."
        case .invalidImageData:
            "The API returned image data that could not be decoded."
        case .invalidCameraJSON:
            "The style JSON is not valid."
        case .invalidModelJSON(let name):
            "The JSON for \(name) is not valid."
        case .missingModelThumbnail(let name):
            "The reference thumbnail for \(name) could not be found."
        case .modelRefreshFailed:
            "Could not refresh image models from the API."
        case .missingAdLocalizationFolder:
            "Choose the folder that contains the static ads to localize."
        case .missingAdLocalizationLanguages:
            "Choose at least one language + currency market for ad localization."
        case .emptyAdLocalizationFolder:
            "The selected folder does not contain supported image files."
        case .requestTimedOut:
            "Request timed out. Large image generations can take a while, especially at higher quality or with multiple images."
        case .networkConnectionLost:
            "The network connection was lost."
        case .tooManyGeminiReferenceImages(let count):
            "Nano Banana Pro accepts at most 14 reference images. This generation contains \(count)."
        case .apiError(let message):
            message
        }
    }
}

final class APIKeyStore {
    private let defaults = UserDefaults.standard
    private let apiKeyKey = "openai_api_key"
    private let secureStore = SecureAPIKeyStore(
        service: "com.soundbrenner.mediagenerator",
        account: "openai-api-key"
    )
    private let legacyService = "soundbrenner-media-generator"
    private let legacyAccount = "openai-api-key"

    func read() -> String {
        let secureValue = secureStore.read()
        if !secureValue.isEmpty {
            return secureValue
        }

        if let value = defaults.string(forKey: apiKeyKey), !value.isEmpty {
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if (try? secureStore.write(trimmedValue)) != nil {
                defaults.removeObject(forKey: apiKeyKey)
            }
            return trimmedValue
        }

        guard let legacyValue = readLegacyKeychainValueWithoutPrompt(), !legacyValue.isEmpty else {
            return ""
        }
        try? secureStore.write(legacyValue)
        return legacyValue
    }

    func write(_ value: String) throws {
        try secureStore.write(value)
        defaults.removeObject(forKey: apiKeyKey)
    }

    private func readLegacyKeychainValueWithoutPrompt() -> String? {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
            kSecAttrAccount as String: legacyAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }

        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

final class SecureAPIKeyStore {
    private let service: String
    private let account: String

    init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    func read() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return ""
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func write(_ value: String) throws {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        if trimmedValue.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw keychainError(status)
            }
            return
        }

        let encodedValue = Data(trimmedValue.utf8)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: encodedValue] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw keychainError(updateStatus)
        }

        var insert = query
        insert[kSecValueData as String] = encodedValue
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let insertStatus = SecItemAdd(insert as CFDictionary, nil)
        guard insertStatus == errSecSuccess else {
            throw keychainError(insertStatus)
        }
    }

    private func keychainError(_ status: OSStatus) -> NSError {
        NSError(
            domain: NSOSStatusErrorDomain,
            code: Int(status),
            userInfo: [
                NSLocalizedDescriptionKey: SecCopyErrorMessageString(status, nil) as String?
                    ?? "Could not save the API key securely."
            ]
        )
    }
}

final class AppPreferencesStore {
    private let defaults = UserDefaults.standard
    private let legacyDefaults = UserDefaults(suiteName: "soundbrenner-media-generator")
    private let formKey = "generator_form"
    private let selectedModelIDKey = "selected_model_id"
    private let selectedModelIDsKey = "selected_model_ids_v2"
    private let useRandomModelKey = "use_random_model"
    private let randomModelModeKey = "random_model_mode"
    private let selectedCameraIDKey = "selected_camera_id"
    private let selectedProductIDKey = "selected_product_id"
    private let selectedAdAngleIDKey = "selected_ad_angle_id"
    private let selectedAdAngleIDsKey = "selected_ad_angle_ids_v2"
    private let randomAdAngleKey = "random_ad_angle"
    private let selectedPromotionalContextIDKey = "selected_promotional_context_id"
    private let selectedPromotionalContextIDsKey = "selected_promotional_context_ids_v2"
    private let randomPromotionalContextKey = "random_promotional_context"
    private let selectedPresetIDsKey = "selected_prompt_preset_ids_v1"
    private let selectedPresetIDListsKey = "selected_prompt_preset_ids_v2"
    private let randomPresetCategoriesKey = "random_prompt_preset_categories_v1"
    private let legacySelectedModelIDsKey = "selected_model_ids"

    func loadForm() -> GenerationForm? {
        if let data = defaults.data(forKey: formKey),
           let form = try? JSONDecoder().decode(GenerationForm.self, from: data) {
            return upgradeImagePreferences(form)
        }

        guard let data = legacyDefaults?.data(forKey: formKey) else {
            return nil
        }

        let form = try? JSONDecoder().decode(GenerationForm.self, from: data)
        return form.map(upgradeImagePreferences)
    }

    private func upgradeImagePreferences(_ savedForm: GenerationForm) -> GenerationForm {
        var form = savedForm
        if !defaults.bool(forKey: "image25_defaults_migrated") {
            form.upgradeLegacyImageDefaults()
            saveForm(form)
            defaults.set(true, forKey: "image25_defaults_migrated")
        }
        return form
    }

    func saveForm(_ form: GenerationForm) {
        guard let data = try? JSONEncoder().encode(form) else {
            return
        }
        defaults.set(data, forKey: formKey)
    }

    func loadSelectedModelID() -> UUID? {
        if let rawValue = defaults.string(forKey: selectedModelIDKey),
           let id = UUID(uuidString: rawValue) {
            return id
        }

        let legacyValues = defaults.stringArray(forKey: legacySelectedModelIDsKey) ?? []
        if let id = legacyValues.compactMap(UUID.init(uuidString:)).first {
            return id
        }

        if let rawValue = legacyDefaults?.string(forKey: selectedModelIDKey),
           let id = UUID(uuidString: rawValue) {
            saveSelectedModelID(id)
            return id
        }

        let legacyStoredValues = legacyDefaults?.stringArray(forKey: legacySelectedModelIDsKey) ?? []
        if let id = legacyStoredValues.compactMap(UUID.init(uuidString:)).first {
            saveSelectedModelID(id)
            return id
        }

        return nil
    }

    func saveSelectedModelID(_ id: UUID?) {
        defaults.set(id?.uuidString, forKey: selectedModelIDKey)
        defaults.removeObject(forKey: legacySelectedModelIDsKey)
    }

    func loadSelectedModelIDs() -> [UUID] {
        if let rawValues = defaults.stringArray(forKey: selectedModelIDsKey),
           !rawValues.isEmpty {
            return rawValues.compactMap(UUID.init(uuidString:))
        }

        if let id = loadSelectedModelID() {
            return [id]
        }

        return []
    }

    func saveSelectedModelIDs(_ ids: [UUID]) {
        defaults.set(ids.map(\.uuidString), forKey: selectedModelIDsKey)
        defaults.set(ids.first?.uuidString, forKey: selectedModelIDKey)
        defaults.removeObject(forKey: legacySelectedModelIDsKey)
    }

    func loadUseRandomModel() -> Bool {
        defaults.bool(forKey: useRandomModelKey)
    }

    func saveUseRandomModel(_ isEnabled: Bool) {
        defaults.set(isEnabled, forKey: useRandomModelKey)
    }

    func loadRandomModelMode() -> RandomModelMode {
        if let rawValue = defaults.string(forKey: randomModelModeKey),
           let mode = RandomModelMode(rawValue: rawValue) {
            return mode
        }

        return loadUseRandomModel() ? .all : .none
    }

    func saveRandomModelMode(_ mode: RandomModelMode) {
        defaults.set(mode.rawValue, forKey: randomModelModeKey)
        defaults.set(mode != .none, forKey: useRandomModelKey)
    }

    func loadSelectedCameraID() -> UUID? {
        if let rawValue = defaults.string(forKey: selectedCameraIDKey),
           let id = UUID(uuidString: rawValue) {
            let remapped = remappedCameraProfileID(id)
            if remapped != id {
                saveSelectedCameraID(remapped)
            }
            return remapped
        }

        if let rawValue = legacyDefaults?.string(forKey: selectedCameraIDKey),
           let id = UUID(uuidString: rawValue) {
            let remapped = remappedCameraProfileID(id)
            saveSelectedCameraID(remapped)
            return remapped
        }

        return nil
    }

    func saveSelectedCameraID(_ id: UUID?) {
        defaults.set(id?.uuidString, forKey: selectedCameraIDKey)
    }

    private func remappedCameraProfileID(_ id: UUID) -> UUID {
        guard
            let migrations = defaults.dictionary(forKey: PreferenceKeys.cameraProfileIDMigrationKey) as? [String: String],
            let migratedRawValue = migrations[id.uuidString],
            let migratedID = UUID(uuidString: migratedRawValue)
        else {
            return id
        }

        return migratedID
    }

    func loadSelectedProductID() -> String? {
        defaults.string(forKey: selectedProductIDKey)
    }

    func saveSelectedProductID(_ id: String?) {
        defaults.set(id, forKey: selectedProductIDKey)
    }

    func loadSelectedAdAngleID() -> String? {
        defaults.string(forKey: selectedAdAngleIDKey)
    }

    func saveSelectedAdAngleID(_ id: String?) {
        defaults.set(id, forKey: selectedAdAngleIDKey)
    }

    func loadSelectedAdAngleIDs() -> [String] {
        if let ids = defaults.stringArray(forKey: selectedAdAngleIDsKey),
           !ids.isEmpty {
            return ids
        }

        return loadSelectedAdAngleID().map { [$0] } ?? []
    }

    func saveSelectedAdAngleIDs(_ ids: [String]) {
        defaults.set(ids, forKey: selectedAdAngleIDsKey)
        defaults.set(ids.first, forKey: selectedAdAngleIDKey)
    }

    func loadRandomAdAngle() -> Bool {
        defaults.bool(forKey: randomAdAngleKey)
    }

    func saveRandomAdAngle(_ isEnabled: Bool) {
        defaults.set(isEnabled, forKey: randomAdAngleKey)
    }

    func loadSelectedPromotionalContextID() -> String? {
        defaults.string(forKey: selectedPromotionalContextIDKey)
    }

    func saveSelectedPromotionalContextID(_ id: String?) {
        defaults.set(id, forKey: selectedPromotionalContextIDKey)
    }

    func loadSelectedPromotionalContextIDs() -> [String] {
        if let ids = defaults.stringArray(forKey: selectedPromotionalContextIDsKey),
           !ids.isEmpty {
            return ids
        }

        if let id = loadSelectedPromotionalContextID() {
            return [id]
        }

        return []
    }

    func saveSelectedPromotionalContextIDs(_ ids: [String]) {
        defaults.set(ids, forKey: selectedPromotionalContextIDsKey)
        defaults.set(ids.first, forKey: selectedPromotionalContextIDKey)
    }

    func loadRandomPromotionalContext() -> Bool {
        defaults.bool(forKey: randomPromotionalContextKey)
    }

    func saveRandomPromotionalContext(_ isEnabled: Bool) {
        defaults.set(isEnabled, forKey: randomPromotionalContextKey)
    }

    func loadSelectedPresetIDs() -> [PromptPresetCategory: String] {
        guard let rawValues = defaults.dictionary(forKey: selectedPresetIDsKey) as? [String: String] else {
            return [:]
        }

        return rawValues.reduce(into: [:]) { result, entry in
            guard let category = PromptPresetCategory.category(forPersistedValue: entry.key) else {
                return
            }
            result[category] = entry.value
        }
    }

    func saveSelectedPresetIDs(_ ids: [PromptPresetCategory: String]) {
        let rawValues = ids.reduce(into: [String: String]()) { result, entry in
            result[entry.key.rawValue] = entry.value
        }
        defaults.set(rawValues, forKey: selectedPresetIDsKey)
    }

    func loadSelectedPresetIDLists() -> [PromptPresetCategory: [String]] {
        if let rawValues = defaults.dictionary(forKey: selectedPresetIDListsKey) as? [String: [String]] {
            return rawValues.reduce(into: [:]) { result, entry in
                guard let category = PromptPresetCategory.category(forPersistedValue: entry.key) else {
                    return
                }
                result[category] = entry.value
            }
        }

        return loadSelectedPresetIDs().mapValues { [$0] }
    }

    func saveSelectedPresetIDLists(_ ids: [PromptPresetCategory: [String]]) {
        let rawValues = ids.reduce(into: [String: [String]]()) { result, entry in
            result[entry.key.rawValue] = entry.value
        }
        defaults.set(rawValues, forKey: selectedPresetIDListsKey)
        saveSelectedPresetIDs(ids.compactMapValues(\.first))
    }

    func loadRandomPresetCategories() -> Set<PromptPresetCategory> {
        let rawValues = defaults.stringArray(forKey: randomPresetCategoriesKey) ?? []
        return Set(rawValues.compactMap(PromptPresetCategory.category(forPersistedValue:)))
    }

    func saveRandomPresetCategories(_ categories: Set<PromptPresetCategory>) {
        defaults.set(categories.map(\.rawValue), forKey: randomPresetCategoriesKey)
    }
}

final class OpenAIImageService: Sendable {
    private static let requestTimeout: TimeInterval = 1_200
    private static let visionQCModels = ["gpt-5.6-luna", "gpt-6-astra"]
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Soundbrenner Pixel",
        category: "OpenAI"
    )

    func fetchAvailableImageModels(apiKey: String) async throws -> [ImageModelOption] {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppError.missingAPIKey
        }

        Self.logger.debug("Refreshing image models from /v1/models")
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let session = Self.makeSession()
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppError.modelRefreshFailed
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = try? JSONDecoder().decode(OpenAIAPIErrorEnvelope.self, from: data)
            throw AppError.apiError(message?.error.message ?? "Model list refresh failed with status \(httpResponse.statusCode).")
        }

        let decoded = try JSONDecoder().decode(OpenAIModelsResponse.self, from: data)
        let ids = decoded.data
            .map(\.id)
            .filter { $0.hasPrefix("gpt-image-") }
            .sorted { lhs, rhs in
                if lhs == rhs { return false }
                if lhs == ImageModelOption.preferredModel { return true }
                if rhs == ImageModelOption.preferredModel { return false }
                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }

        let fallback = Self.defaultImageModels.map(\.id)
        let unique = Array(NSOrderedSet(array: ids + fallback).array.compactMap { $0 as? String })
        Self.logger.debug("Image model refresh succeeded with \(unique.count) results")
        return unique.map(ImageModelOption.init(id:))
    }

    static let defaultImageModels: [ImageModelOption] = [
        ImageModelOption(id: ImageModelOption.preferredModel),
        ImageModelOption(id: "gpt-image-2.5-flare"),
        ImageModelOption(id: GeminiImageService.nanoBananaProModel),
        ImageModelOption(id: "gpt-image-2"),
        ImageModelOption(id: "gpt-image-2-2026-04-21"),
        ImageModelOption(id: "gpt-image-1.5"),
        ImageModelOption(id: "gpt-image-1-mini")
    ]

    func generateImages(apiKey: String, form: GenerationForm, referenceImageURLs: [URL]) async throws -> [GeneratedImagePayload] {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppError.missingAPIKey
        }

        guard !form.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppError.missingPrompt
        }

        if referenceImageURLs.isEmpty {
            return try await generateFromPrompt(apiKey: apiKey, form: form)
        }

        return try await generateWithReferences(apiKey: apiKey, form: form, referenceImageURLs: referenceImageURLs)
    }

    func editImage(
        apiKey: String,
        imageURL: URL,
        prompt: String,
        model: String,
        quality: ImageQuality,
        size: String,
        outputFormat: OutputFormat,
        moderation: ModerationLevel
    ) async throws -> GeneratedImagePayload {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppError.missingAPIKey
        }

        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppError.missingPrompt
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/images/edits")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("", forHTTPHeaderField: "Expect")
        request.httpBody = try buildMultipartBody(
            model: model,
            prompt: prompt,
            size: size,
            quality: quality,
            imageCount: 1,
            outputFormat: outputFormat,
            outputCompression: nil,
            moderation: moderation,
            referenceImageURLs: [imageURL],
            boundary: boundary
        )
        request.timeoutInterval = Self.requestTimeout

        let (data, response) = try await perform(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = try? JSONDecoder().decode(OpenAIAPIErrorEnvelope.self, from: data)
            throw AppError.apiError(message?.error.message ?? "Reference-image generation failed with status \(httpResponse.statusCode).")
        }

        let decoded = try JSONDecoder().decode(OpenAIImageGenerationResponse.self, from: data)
        guard let item = decoded.data.first,
              let imageData = Data(base64Encoded: item.b64JSON) else {
            throw AppError.invalidImageData
        }

        return GeneratedImagePayload(data: imageData, format: outputFormat)
    }

    fileprivate func analyzeAdLocalizationSource(
        apiKey: String,
        imageURL: URL,
        language: AdLocalizationLanguage,
        truthContext: String?
    ) async throws -> AdLocalizationSourceIntent {
        let prompt = """
        Analyze this source Meta ad before localization.

        Return JSON only. Identify what is visibly present in the source ad; do not infer hidden offers.

        Target: \(language.title)

        Live truth context for product names and prices:
        \(truthContext ?? "No live truth context available.")

        Required JSON shape:
        {
          "detectedProduct": "soundbrenner-wave-pro-in-ear-monitors or unknown",
          "visibleOfferType": "none|amount_off|discount_percent|price|price_compare_at|shipping|mixed",
          "visiblePriceFields": ["all visible price or savings strings, e.g. $349, $199, SAVE 150 USD, $15, $39, $9"],
          "visibleDiscountPercentFields": ["all visible percentage-off strings, e.g. 43% OFF, UP TO 43% OFF, 43% OFF SITE WIDE"],
          "visibleComponentPriceFields": ["only itemized bundle/accessory/component prices, e.g. $15, $39, $9"],
          "hasVisiblePrice": true,
          "hasCompareAtPrice": false,
          "hasAmountOffClaim": true,
          "hasDiscountPercentClaim": false,
          "hasShippingClaim": true,
          "hasShippingThreshold": false,
          "notes": ["short factual observations"]
        }
        """

        return try await performVisionJSONRequest(
            apiKey: apiKey,
            prompt: prompt,
            imagePayloads: [try imagePayload(url: imageURL)],
            responseType: AdLocalizationSourceIntent.self
        )
    }

    fileprivate func validateAdLocalizationOutput(
        apiKey: String,
        sourceURL: URL,
        outputData: Data,
        language: AdLocalizationLanguage,
        truthContext: String?,
        sourceIntent: AdLocalizationSourceIntent
    ) async throws -> AdLocalizationQCResult {
        let intentData = try JSONEncoder().encode(sourceIntent)
        let intentText = String(data: intentData, encoding: .utf8) ?? "{}"
        let prompt = """
        Quality-check this localized ad image.

        You receive two images:
        1. Source ad
        2. Localized output ad

        Return JSON only:
        {
          "pass": true,
          "errors": [],
          "notes": ["short notes"]
        }

        Source intent JSON:
        \(intentText)

        Target: \(language.title)

        Live truth context:
        \(truthContext ?? "No live truth context available.")

        Fail the output if any of these are true:
        - It added a compare-at/original price when sourceIntent.hasCompareAtPrice is false.
        - It added a product price when sourceIntent.hasVisiblePrice is false and the source only had a percent discount or amount-off claim.
        - It added an amount-off claim when sourceIntent.hasAmountOffClaim is false.
        - It has an amount-off claim but the number/currency does not match the selected product's marketing amount-off display in the live truth context.
        - It has a percent-off claim but the percentage does not match the percent-off truth in the live truth context.
        - It has a percent-off claim in a non-English target and leaves English percentage-off wording such as "OFF", "off", "SITE WIDE", or "SALE" visible. The number and % sign may remain, but the surrounding offer words must be localized.
        - It adds a percent-off claim when sourceIntent.hasDiscountPercentClaim is false.
        - It leaves an itemized bundle component or accessory price in USD when the live truth context provides an exact component price match for that USD amount.
        - It changes a component/accessory line from FREE to a paid price, or removes FREE when FREE is visible in the source.
        - It keeps the source USD amount in an English non-US target market. Example: fail "$150 OFF" for English + CAD when the live truth context says marketing amount-off CA$230.
        - It omits the target-market currency marker for an amount-off claim when the truth context includes one, such as CA$, AU$, £, €, ¥, or ₩.
        - It added shipping text when sourceIntent.hasShippingClaim is false.
        - It added a shipping threshold when sourceIntent.hasShippingThreshold is false.
        - It uses USD text, "US$," or a bare "$" amount in a non-USD target market. For CAD and AUD, CA$ and AU$ are allowed and should be required when the truth context uses them.
        - It formats Japanese yen or Korean won with broken digit grouping, such as misplaced commas or four trailing zeroes after a comma.
        - It uses formal German address such as Sie, Ihnen, Ihr, Ihre for German.
        - It changes the offer structure instead of replacing existing visible claims.
        - It mistranslates obvious CTA/UI text.
        - It leaves major English offer copy visible when the target language is not English.

        Do not fail for small visual differences that are normal in image generation. Focus on semantic ad-copy and offer mistakes.
        """

        return try await performVisionJSONRequest(
            apiKey: apiKey,
            prompt: prompt,
            imagePayloads: [
                try imagePayload(url: sourceURL),
                imagePayload(data: outputData, mimeType: "image/png")
            ],
            responseType: AdLocalizationQCResult.self
        )
    }

    private func generateFromPrompt(apiKey: String, form: GenerationForm) async throws -> [GeneratedImagePayload] {
        let body = form.requestBody

        Self.logger.debug(
            "Starting prompt image generation with model \(form.imageModel, privacy: .public), quality \(form.quality.rawValue, privacy: .public), size \(form.resolution.sizeValue, privacy: .public), count \(form.sanitizedImageCount)"
        )
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/images/generations")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        request.timeoutInterval = Self.requestTimeout

        let (data, response) = try await perform(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = try? JSONDecoder().decode(OpenAIAPIErrorEnvelope.self, from: data)
            throw AppError.apiError(message?.error.message ?? "Image generation failed with status \(httpResponse.statusCode).")
        }

        let decoded = try JSONDecoder().decode(OpenAIImageGenerationResponse.self, from: data)
        let payloads = try decoded.data.map { item in
            guard let imageData = Data(base64Encoded: item.b64JSON) else {
                throw AppError.invalidImageData
            }
            return GeneratedImagePayload(data: imageData, format: form.outputFormat)
        }

        if payloads.isEmpty {
            throw AppError.invalidResponse
        }

        Self.logger.debug("Prompt image generation succeeded with \(payloads.count) image payloads")
        return payloads
    }

    private func generateWithReferences(apiKey: String, form: GenerationForm, referenceImageURLs: [URL]) async throws -> [GeneratedImagePayload] {
        let boundary = "Boundary-\(UUID().uuidString)"
        Self.logger.debug(
            "Starting reference image generation with model \(form.imageModel, privacy: .public), quality \(form.quality.rawValue, privacy: .public), size \(form.resolution.sizeValue, privacy: .public), refs \(referenceImageURLs.count)"
        )
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/images/edits")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("", forHTTPHeaderField: "Expect")
        request.httpBody = try buildMultipartBody(form: form, referenceImageURLs: referenceImageURLs, boundary: boundary)
        request.timeoutInterval = Self.requestTimeout

        let (data, response) = try await perform(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = try? JSONDecoder().decode(OpenAIAPIErrorEnvelope.self, from: data)
            throw AppError.apiError(message?.error.message ?? "Reference-image generation failed with status \(httpResponse.statusCode).")
        }

        let decoded = try JSONDecoder().decode(OpenAIImageGenerationResponse.self, from: data)
        let payloads = try decoded.data.map { item in
            guard let imageData = Data(base64Encoded: item.b64JSON) else {
                throw AppError.invalidImageData
            }
            return GeneratedImagePayload(data: imageData, format: form.outputFormat)
        }

        if payloads.isEmpty {
            throw AppError.invalidResponse
        }

        Self.logger.debug("Reference image generation succeeded with \(payloads.count) image payloads")
        return payloads
    }

    private func buildMultipartBody(form: GenerationForm, referenceImageURLs: [URL], boundary: String) throws -> Data {
        try buildMultipartBody(
            model: form.imageModel,
            prompt: form.prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            size: form.resolution.sizeValue,
            quality: form.quality,
            imageCount: form.sanitizedImageCount,
            outputFormat: form.outputFormat,
            outputCompression: form.outputFormat == .png ? nil : form.outputCompression,
            moderation: form.moderation,
            referenceImageURLs: referenceImageURLs,
            boundary: boundary
        )
    }

    private func buildMultipartBody(
        model: String,
        prompt: String,
        size: String,
        quality: ImageQuality,
        imageCount: Int,
        outputFormat: OutputFormat,
        outputCompression: Int?,
        moderation: ModerationLevel,
        referenceImageURLs: [URL],
        boundary: String
    ) throws -> Data {
        var body = Data()

        func appendField(name: String, value: String) {
            body.appendString("--\(boundary)\r\n")
            body.appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.appendString("\(value)\r\n")
        }

        func appendFile(name: String, url: URL) throws {
            let data = try Data(contentsOf: url)
            let mimeType = mimeTypeForFileExtension(url.pathExtension)
            body.appendString("--\(boundary)\r\n")
            body.appendString("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(url.lastPathComponent)\"\r\n")
            body.appendString("Content-Type: \(mimeType)\r\n\r\n")
            body.append(data)
            body.appendString("\r\n")
        }

        appendField(name: "model", value: model)
        appendField(name: "prompt", value: prompt)
        appendField(name: "size", value: size)
        appendField(name: "quality", value: quality.rawValue)
        appendField(name: "n", value: String(imageCount))
        appendField(name: "output_format", value: outputFormat.rawValue)
        appendField(name: "moderation", value: moderation.rawValue)

        if let outputCompression {
            appendField(name: "output_compression", value: String(outputCompression))
        }

        for url in referenceImageURLs {
            try appendFile(name: "image[]", url: url)
        }

        body.appendString("--\(boundary)--\r\n")
        return body
    }

    private func mimeTypeForFileExtension(_ ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg":
            "image/jpeg"
        case "webp":
            "image/webp"
        case "heic":
            "image/heic"
        case "gif":
            "image/gif"
        default:
            "image/png"
        }
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let requestDescription = "\(request.httpMethod ?? "GET") \(request.url?.path ?? "<unknown>")"
        do {
            let session = Self.makeSession()
            return try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            Self.logger.error("\(requestDescription, privacy: .public) timed out")
            throw AppError.requestTimedOut
        } catch let error as URLError where error.code.isTransientConnectionFailure {
            Self.logger.error("\(requestDescription, privacy: .public) connection failed with \(error.code.rawValue)")
            throw AppError.networkConnectionLost
        } catch {
            Self.logger.error("\(requestDescription, privacy: .public) failed with \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    private func performVisionJSONRequest<T: Decodable>(
        apiKey: String,
        prompt: String,
        imagePayloads: [[String: Any]],
        responseType: T.Type
    ) async throws -> T {
        var lastError: Error?
        for model in Self.visionQCModels {
            do {
                return try await performVisionJSONRequest(
                    apiKey: apiKey,
                    model: model,
                    prompt: prompt,
                    imagePayloads: imagePayloads,
                    responseType: responseType
                )
            } catch {
                lastError = error
                if case AppError.apiError(let message) = error,
                   message.localizedCaseInsensitiveContains("model") {
                    continue
                }
                throw error
            }
        }
        throw lastError ?? AppError.invalidResponse
    }

    private func performVisionJSONRequest<T: Decodable>(
        apiKey: String,
        model: String,
        prompt: String,
        imagePayloads: [[String: Any]],
        responseType: T.Type
    ) async throws -> T {
        var content: [[String: Any]] = [["type": "text", "text": prompt]]
        content.append(contentsOf: imagePayloads.map { payload in
            ["type": "image_url", "image_url": payload]
        })

        var body: [String: Any] = [
            "model": model,
            "messages": [
                [
                    "role": "system",
                    "content": "You are a strict localization QA reviewer for consumer electronics Meta ads. Return valid JSON only."
                ],
                [
                    "role": "user",
                    "content": content
                ]
            ],
            "response_format": ["type": "json_object"]
        ]
        if model.hasPrefix("gpt-5") || model.hasPrefix("gpt-6") {
            body["reasoning_effort"] = "low"
        } else {
            body["temperature"] = 0
        }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = Self.requestTimeout

        let (data, response) = try await perform(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = try? JSONDecoder().decode(OpenAIAPIErrorEnvelope.self, from: data)
            throw AppError.apiError(message?.error.message ?? "Vision QC failed with status \(httpResponse.statusCode).")
        }

        let decoded = try JSONDecoder().decode(OpenAIChatCompletionResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content,
              let jsonData = content.data(using: .utf8) else {
            throw AppError.invalidResponse
        }
        return try JSONDecoder().decode(responseType, from: jsonData)
    }

    private func imagePayload(url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return imagePayload(data: data, mimeType: mimeTypeForFileExtension(url.pathExtension))
    }

    private func imagePayload(data: Data, mimeType: String) -> [String: Any] {
        [
            "url": "data:\(mimeType);base64,\(data.base64EncodedString())"
        ]
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        configuration.waitsForConnectivity = true
        configuration.httpShouldUsePipelining = false
        return URLSession(configuration: configuration)
    }
}

final class GeminiImageService: Sendable {
    static let nanoBananaProModel = "gemini-3-pro-image"
    private static let requestTimeout: TimeInterval = 1_200
    private static let maximumReferenceImageCount = 14
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Soundbrenner Pixel",
        category: "Gemini"
    )

    static func generationConfiguration(
        aspectRatio: GeminiAspectRatio,
        imageSize: GeminiImageSize
    ) -> [String: Any] {
        [
            "responseModalities": ["IMAGE"],
            "imageConfig": [
                "aspectRatio": aspectRatio.rawValue,
                "imageSize": imageSize.rawValue
            ]
        ]
    }

    func validateAPIKey(_ apiKey: String) async throws {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw AppError.missingGeminiAPIKey
        }

        var request = URLRequest(
            url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(Self.nanoBananaProModel)")!
        )
        request.httpMethod = "GET"
        request.setValue(trimmedKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 60

        let (data, response) = try await perform(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw geminiAPIError(data: data, statusCode: httpResponse.statusCode)
        }
    }

    func generateImages(
        apiKey: String,
        form: GenerationForm,
        referenceImageURLs: [URL]
    ) async throws -> [GeneratedImagePayload] {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw AppError.missingGeminiAPIKey
        }
        guard !form.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppError.missingPrompt
        }
        guard referenceImageURLs.count <= Self.maximumReferenceImageCount else {
            throw AppError.tooManyGeminiReferenceImages(referenceImageURLs.count)
        }

        var payloads = [GeneratedImagePayload]()
        payloads.reserveCapacity(form.sanitizedImageCount)
        for _ in 0..<form.sanitizedImageCount {
            payloads.append(
                try await generateSingleImage(
                    apiKey: trimmedKey,
                    form: form,
                    referenceImageURLs: referenceImageURLs
                )
            )
        }
        return payloads
    }

    private func generateSingleImage(
        apiKey: String,
        form: GenerationForm,
        referenceImageURLs: [URL]
    ) async throws -> GeneratedImagePayload {
        var parts: [[String: Any]] = [
            ["text": form.prompt.trimmingCharacters(in: .whitespacesAndNewlines)]
        ]
        for referenceURL in referenceImageURLs {
            let data = try Data(contentsOf: referenceURL)
            parts.append([
                "inlineData": [
                    "mimeType": mimeType(for: referenceURL),
                    "data": data.base64EncodedString()
                ]
            ])
        }

        let body: [String: Any] = [
            "contents": [
                [
                    "role": "user",
                    "parts": parts
                ]
            ],
            "generationConfig": Self.generationConfiguration(
                aspectRatio: form.geminiAspectRatio,
                imageSize: form.geminiImageSize
            )
        ]

        let model = form.imageModel.isGeminiImageModel
            ? form.imageModel
            : Self.nanoBananaProModel
        var request = URLRequest(
            url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
        )
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = Self.requestTimeout

        Self.logger.debug(
            "Starting Nano Banana Pro generation at \(form.geminiImageSize.rawValue, privacy: .public), \(form.geminiAspectRatio.rawValue, privacy: .public), refs \(referenceImageURLs.count)"
        )
        let (data, response) = try await perform(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw geminiAPIError(data: data, statusCode: httpResponse.statusCode)
        }

        let decoded = try JSONDecoder().decode(GeminiGenerateContentResponse.self, from: data)
        let responseParts = (decoded.candidates ?? []).flatMap(\.content.parts)
        guard let imagePart = responseParts.first(where: { $0.thought != true && $0.inlineData != nil }),
              let inlineData = imagePart.inlineData,
              let imageData = Data(base64Encoded: inlineData.data) else {
            throw AppError.invalidImageData
        }

        Self.logger.debug("Nano Banana Pro generation succeeded")
        return GeneratedImagePayload(
            data: imageData,
            format: outputFormat(for: inlineData.mimeType)
        )
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = Self.requestTimeout
            configuration.timeoutIntervalForResource = Self.requestTimeout
            configuration.waitsForConnectivity = true
            return try await URLSession(configuration: configuration).data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw AppError.requestTimedOut
        } catch let error as URLError where error.code.isTransientConnectionFailure {
            throw AppError.networkConnectionLost
        }
    }

    private func geminiAPIError(data: Data, statusCode: Int) -> AppError {
        let message = try? JSONDecoder().decode(GeminiAPIErrorEnvelope.self, from: data)
        return .apiError(
            message?.error.message
                ?? "Nano Banana Pro failed with status \(statusCode)."
        )
    }

    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg":
            "image/jpeg"
        case "webp":
            "image/webp"
        case "heic":
            "image/heic"
        case "gif":
            "image/gif"
        default:
            "image/png"
        }
    }

    private func outputFormat(for mimeType: String) -> OutputFormat {
        switch mimeType.lowercased() {
        case "image/jpeg", "image/jpg":
            .jpeg
        case "image/webp":
            .webp
        default:
            .png
        }
    }
}

private struct OpenAIAPIErrorEnvelope: Decodable {
    let error: OpenAIAPIError
}

private struct OpenAIAPIError: Decodable {
    let message: String
}

private struct GeminiAPIErrorEnvelope: Decodable {
    let error: GeminiAPIError
}

private struct GeminiAPIError: Decodable {
    let message: String
}

private struct GeminiGenerateContentResponse: Decodable {
    let candidates: [Candidate]?

    struct Candidate: Decodable {
        let content: Content
    }

    struct Content: Decodable {
        let parts: [Part]
    }

    struct Part: Decodable {
        let text: String?
        let inlineData: InlineData?
        let thought: Bool?
    }

    struct InlineData: Decodable {
        let mimeType: String
        let data: String
    }
}

private struct ImageGenerationResult {
    let payloads: [GeneratedImagePayload]
    let form: GenerationForm
    let usedQualityFallback: Bool
}

private struct OpenAIModelsResponse: Decodable {
    let data: [OpenAIModelRecord]
}

private struct OpenAIModelRecord: Decodable {
    let id: String
}

private struct OpenAIChatCompletionResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: Message
    }

    struct Message: Decodable {
        let content: String?
    }
}

private struct AdLocalizationSourceIntent: Codable, Hashable {
    let detectedProduct: String
    let visibleOfferType: String
    let visiblePriceFields: [String]
    let visibleDiscountPercentFields: [String]
    let visibleComponentPriceFields: [String]
    let hasVisiblePrice: Bool
    let hasCompareAtPrice: Bool
    let hasAmountOffClaim: Bool
    let hasDiscountPercentClaim: Bool
    let hasShippingClaim: Bool
    let hasShippingThreshold: Bool
    let notes: [String]

    static let fallback = AdLocalizationSourceIntent(
        detectedProduct: "unknown",
        visibleOfferType: "unknown",
        visiblePriceFields: [],
        visibleDiscountPercentFields: [],
        visibleComponentPriceFields: [],
        hasVisiblePrice: false,
        hasCompareAtPrice: false,
        hasAmountOffClaim: false,
        hasDiscountPercentClaim: false,
        hasShippingClaim: false,
        hasShippingThreshold: false,
        notes: ["Source intent analysis unavailable."]
    )

    enum CodingKeys: String, CodingKey {
        case detectedProduct
        case visibleOfferType
        case visiblePriceFields
        case visibleDiscountPercentFields
        case visibleComponentPriceFields
        case hasVisiblePrice
        case hasCompareAtPrice
        case hasAmountOffClaim
        case hasDiscountPercentClaim
        case hasShippingClaim
        case hasShippingThreshold
        case notes
    }

    init(
        detectedProduct: String,
        visibleOfferType: String,
        visiblePriceFields: [String],
        visibleDiscountPercentFields: [String],
        visibleComponentPriceFields: [String],
        hasVisiblePrice: Bool,
        hasCompareAtPrice: Bool,
        hasAmountOffClaim: Bool,
        hasDiscountPercentClaim: Bool,
        hasShippingClaim: Bool,
        hasShippingThreshold: Bool,
        notes: [String]
    ) {
        self.detectedProduct = detectedProduct
        self.visibleOfferType = visibleOfferType
        self.visiblePriceFields = visiblePriceFields
        self.visibleDiscountPercentFields = visibleDiscountPercentFields
        self.visibleComponentPriceFields = visibleComponentPriceFields
        self.hasVisiblePrice = hasVisiblePrice
        self.hasCompareAtPrice = hasCompareAtPrice
        self.hasAmountOffClaim = hasAmountOffClaim
        self.hasDiscountPercentClaim = hasDiscountPercentClaim
        self.hasShippingClaim = hasShippingClaim
        self.hasShippingThreshold = hasShippingThreshold
        self.notes = notes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        detectedProduct = try container.decodeIfPresent(String.self, forKey: .detectedProduct) ?? "unknown"
        visibleOfferType = try container.decodeIfPresent(String.self, forKey: .visibleOfferType) ?? "unknown"
        visiblePriceFields = try container.decodeIfPresent([String].self, forKey: .visiblePriceFields) ?? []
        visibleDiscountPercentFields = try container.decodeIfPresent([String].self, forKey: .visibleDiscountPercentFields) ?? []
        visibleComponentPriceFields = try container.decodeIfPresent([String].self, forKey: .visibleComponentPriceFields) ?? []
        hasVisiblePrice = try container.decodeIfPresent(Bool.self, forKey: .hasVisiblePrice) ?? false
        hasCompareAtPrice = try container.decodeIfPresent(Bool.self, forKey: .hasCompareAtPrice) ?? false
        hasAmountOffClaim = try container.decodeIfPresent(Bool.self, forKey: .hasAmountOffClaim) ?? false
        hasDiscountPercentClaim = try container.decodeIfPresent(Bool.self, forKey: .hasDiscountPercentClaim) ?? false
        hasShippingClaim = try container.decodeIfPresent(Bool.self, forKey: .hasShippingClaim) ?? false
        hasShippingThreshold = try container.decodeIfPresent(Bool.self, forKey: .hasShippingThreshold) ?? false
        notes = try container.decodeIfPresent([String].self, forKey: .notes) ?? []
    }

    var promptContext: String {
        """
        Source intent detected by vision QC:
        - Product: \(detectedProduct)
        - Visible offer type: \(visibleOfferType)
        - Visible price fields: \(visiblePriceFields.isEmpty ? "none" : visiblePriceFields.joined(separator: " | "))
        - Visible percent-off fields: \(visibleDiscountPercentFields.isEmpty ? "none" : visibleDiscountPercentFields.joined(separator: " | "))
        - Visible component/accessory price fields: \(visibleComponentPriceFields.isEmpty ? "none" : visibleComponentPriceFields.joined(separator: " | "))
        - Has visible product price: \(hasVisiblePrice ? "yes" : "no")
        - Has compare-at/original price: \(hasCompareAtPrice ? "yes" : "no")
        - Has amount-off claim: \(hasAmountOffClaim ? "yes" : "no")
        - Has discount-percent claim: \(hasDiscountPercentClaim ? "yes" : "no")
        - Has shipping claim: \(hasShippingClaim ? "yes" : "no")
        - Has shipping threshold: \(hasShippingThreshold ? "yes" : "no")
        - Notes: \(notes.isEmpty ? "none" : notes.joined(separator: " | "))
        """
    }

    var hasCurrencySpecificLocalizationNeed: Bool {
        hasVisiblePrice
            || hasCompareAtPrice
            || hasAmountOffClaim
            || hasDiscountPercentClaim
            || hasShippingThreshold
            || !visiblePriceFields.isEmpty
            || !visibleDiscountPercentFields.isEmpty
            || !visibleComponentPriceFields.isEmpty
    }
}

private struct AdLocalizationQCResult: Decodable, Hashable {
    let pass: Bool
    let errors: [String]
    let notes: [String]?
}

private struct AdLocalizationQCFailure: LocalizedError {
    let errors: [String]

    var errorDescription: String? {
        guard !errors.isEmpty else {
            return "Localized ad failed semantic QC."
        }
        return "Localized ad failed semantic QC: \(errors.joined(separator: "; "))"
    }
}

private enum AdLocalizationRunResult {
    case generated(GeneratedImagePayload)
    case skipped(String)
}

private struct AdLocalizationTruthPacket {
    let fetchedAt: Date
    let selectedProduct: AdLocalizationProduct
    let articleURL: String?
    let articleURLMatched: Bool
    let articles: AudioChronicleArticleIndex
    let pricesByMarket: [AdLocalizationLanguage: SoundbrennerPriceResponse]
    let discountByMarket: [AdLocalizationLanguage: AdLocalizationDiscountInfo]
    let componentPriceMatchesByMarket: [AdLocalizationLanguage: [AdLocalizationComponentPriceMatch]]
    let shippingByMarket: [AdLocalizationLanguage: AdLocalizationShippingInfo]

    func promptContext(
        for market: AdLocalizationLanguage,
        componentPriceFields: [String] = [],
        includeComponentPriceMatches: Bool = true
    ) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var lines: [String] = [
            "Live localization truth packet fetched at \(formatter.string(from: fetchedAt)).",
            "Target market: \(market.title). Target locale: \(market.localeName). Target currency: \(market.currencyCode).",
            selectedProduct == .none
                ? "Selected product for this run: None. No product price or savings truth was selected."
                : "Selected product for this run: \(selectedProduct.productName). Use only this product's price truth.",
            selectedProduct == .none
                ? "If the source image contains product prices or savings, preserve the source offer text rather than inventing localized price truth."
                : "If the source image appears to advertise a different product, preserve the source offer text rather than borrowing another product's price.",
            "",
            "Price truth:",
            "- Use these exact current prices only when the source image already contains a visible price, amount-off claim, compare-at price, sale price, or discount claim.",
            "- Replace old source-image currency amounts with the target-market values below when the product clearly matches, but keep the same offer structure as the source.",
            "- If the source image has an amount-off claim such as \"$150 off\", use the target-market marketing amount-off display below exactly. It is derived from local compare/base price minus local discounted price and rounded down to a clean safe marketing value.",
            "- Source ads are normally authored in USD. For non-US target markets, never keep the original USD amount just because the copy is already English. For example, if the truth packet says marketing amount-off CA$230, visible text like \"$150 OFF\" is wrong.",
            "- If the source image has a percent-off claim such as \"43% off\" or \"up to 43% off\", use the percent-off truth below exactly.",
            "- When phrase guidance uses {percent}, replace it with the live numeric percent from the Percent-off truth section. Never print {percent} literally.",
            "- For non-English targets, localize the percentage-off words too. Keep the numeric percentage accurate, but never leave English wording like \"OFF\", \"off\", \"SITE WIDE\", or \"SALE\" around a percent claim unless it is part of a brand name or promo code.",
            "- Do not add a compare-at/original price unless the source image already shows a compare-at/original price.",
            "- Do not add an amount-off claim unless the source image already shows an amount-off claim.",
            "- If the source image contains a price for an unknown product, preserve it rather than inventing a conversion."
        ]

        if selectedProduct == .none {
            lines.append("- No product selected. Preserve source prices and savings; do not localize product price or savings amounts.")
        } else if let prices = pricesByMarket[market] {
            lines.append(contentsOf: prices.promptLines)
        } else {
            lines.append("- No live price payload was available for this market. Preserve any existing product prices.")
        }

        lines.append("")
        lines.append("Percent-off truth:")
        lines.append("- Use percent-off data only when the source image already contains a visible percent-off claim.")
        if let discount = discountByMarket[market] {
            lines.append(contentsOf: discount.promptLines)
        } else {
            lines.append("- No live percent-off payload was available for this market. Preserve any existing percent-off claims.")
        }

        lines.append("")
        lines.append("Component price truth:")
        lines.append("- Use these USD-to-local Shopify price matches only for itemized bundle components, accessories, struck-through component prices, or small line-item prices in the source image.")
        lines.append("- If multiple Shopify items share the same USD price, Pixel uses the first stable match. This is intentionally better than leaving a visible component price in USD.")
        lines.append("- Do not use component price matches for the main selected product price, sale price, compare-at price, amount-off claim, or percent-off claim.")
        let filteredMatches = includeComponentPriceMatches
            ? componentPriceMatches(for: market, matching: componentPriceFields)
            : []
        if !includeComponentPriceMatches {
            lines.append("- Component price matches are withheld during source analysis. First classify visible component prices from the source image.")
        } else if componentPriceFields.isEmpty {
            lines.append("- No component/accessory price fields were detected in source analysis. Do not localize component line-item prices.")
        } else if !filteredMatches.isEmpty {
            lines.append(contentsOf: filteredMatches.map(\.promptLine))
        } else {
            lines.append("- No Shopify component price matches were available for detected source component prices: \(componentPriceFields.joined(separator: " | ")). Preserve those component line-item prices rather than guessing.")
        }

        lines.append("")
        lines.append("Shipping truth:")
        lines.append("- Use shipping data only when the source image already contains a visible shipping claim.")
        lines.append("- Do not add a shipping threshold unless the source image already shows a threshold-style shipping claim.")
        if let shipping = shippingByMarket[market] {
            lines.append(contentsOf: shipping.promptLines(for: market))
        } else {
            lines.append("- No live shipping-threshold payload was available for this market. Do not invent a free-shipping threshold.")
        }

        let localizedArticles = articles.promptLines(for: market.languageCode)
        lines.append("")
        lines.append("Audio Chronicle article title truth:")
        if let articleURL, !articleURL.isEmpty {
            lines.append("- Audio Chronicle link selected for this run: \(articleURL).")
            lines.append("- If visible ad text mentions this article title, URL, slug, or close variant from the match strings below, use the exact localized title and URL for \(market.localeName).")
            lines.append("- Do not translate Audio Chronicle article names freely when a canonical localized title is supplied.")
            if !articleURLMatched {
                lines.append("- Warning: the selected Audio Chronicle link did not match the article index. Preserve visible article titles rather than inventing localized article names.")
            }
        } else {
            lines.append("- No Audio Chronicle link was selected for this run.")
            lines.append("- Do not invent or freely translate Audio Chronicle article titles. Preserve visible article titles unless they are ordinary ad copy.")
        }
        lines.append(contentsOf: localizedArticles)

        return lines.joined(separator: "\n")
    }

    private func componentPriceMatches(
        for market: AdLocalizationLanguage,
        matching componentPriceFields: [String]
    ) -> [AdLocalizationComponentPriceMatch] {
        guard let matches = componentPriceMatchesByMarket[market], !matches.isEmpty else {
            return []
        }
        let detectedCents = Set(componentPriceFields.flatMap(Self.usdCentAmounts(in:)))
        guard !detectedCents.isEmpty else {
            return []
        }
        return matches.filter { match in
            !Set(Self.usdCentAmounts(in: match.sourceUSDDisplay)).isDisjoint(with: detectedCents)
        }
    }

    private static func usdCentAmounts(in value: String) -> [Int] {
        let pattern = #"(?i)(?:US\$|\$|USD\s*)(\d+(?:[,.]\d{1,2})?)|(\d+(?:[,.]\d{1,2})?)\s*USD"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let nsRange = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.matches(in: value, range: nsRange).compactMap { match in
            for index in 1..<match.numberOfRanges {
                let range = match.range(at: index)
                guard range.location != NSNotFound,
                      let swiftRange = Range(range, in: value) else {
                    continue
                }
                let rawAmount = value[swiftRange].replacingOccurrences(of: ",", with: ".")
                if let amount = Double(rawAmount) {
                    return Int((amount * 100).rounded())
                }
            }
            return nil
        }
    }
}

private struct AdLocalizationShippingInfo {
    var countryCode: String
    var shipsToCountry: Bool
    var hasFreeShipping: Bool
    var threshold: Double?
    var currency: String
    var advertisedMinTime: String?
    var advertisedMaxTime: String?

    func promptLines(for market: AdLocalizationLanguage) -> [String] {
        var lines = [
            "- Ships to \(countryCode): \(shipsToCountry ? "yes" : "no").",
            "- Free shipping available: \(hasFreeShipping ? "yes" : "no")."
        ]

        if let threshold {
            lines.append("- Free shipping threshold: \(formatAmount(threshold, currency: currency, market: market)).")
        } else if hasFreeShipping {
            lines.append("- Free shipping threshold: none returned by Shopify. Mention free shipping only when the source ad already does.")
        }

        if let advertisedMinTime, let advertisedMaxTime, !advertisedMinTime.isEmpty, !advertisedMaxTime.isEmpty {
            lines.append("- Advertised delivery window: \(advertisedMinTime)-\(advertisedMaxTime).")
        }

        return lines
    }

    private func formatAmount(_ amount: Double, currency: String, market: AdLocalizationLanguage) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.maximumFractionDigits = 0
        formatter.locale = Locale(identifier: market.localeIdentifier)
        return formatter.string(from: NSNumber(value: amount.rounded())) ?? "\(currency) \(Int(amount.rounded()))"
    }
}

private struct AdLocalizationDiscountInfo {
    var sitewidePercentage: Double
    var maxAdvertisedPercentage: Double
    var maxAdvertisedProductName: String?
    var generatedAt: String?
    var syncedAt: String?

    var promptLines: [String] {
        var lines = [
            "- Sitewide discount snapshot: \(percentText(sitewidePercentage)).",
            "- Maximum advertised percent-off claim: \(percentText(maxAdvertisedPercentage))\(maxAdvertisedProductName.map { " from \($0)" } ?? "")."
        ]

        if let generatedAt, !generatedAt.isEmpty {
            lines.append("- Discount snapshot generated at: \(generatedAt).")
        }
        if let syncedAt, !syncedAt.isEmpty {
            lines.append("- Discount snapshot synced at: \(syncedAt).")
        }

        return lines
    }

    private func percentText(_ value: Double) -> String {
        let rounded = value.rounded()
        if abs(value - rounded) < 0.05 {
            return "\(Int(rounded))%"
        }
        return "\(value.formatted(.number.precision(.fractionLength(1))))%"
    }
}

private struct AdLocalizationComponentPriceMatch {
    var sourceUSDDisplay: String
    var targetDisplay: String
    var exampleTitles: [String]

    var promptLine: String {
        let examples = exampleTitles.prefix(3).joined(separator: " | ")
        return "- \(sourceUSDDisplay) -> \(targetDisplay)\(examples.isEmpty ? "" : " [matches: \(examples)]")"
    }
}

private struct AudioChronicleArticleIndex: Decodable {
    let generatedAt: String?
    let articleCount: Int?
    let articles: [Article]

    struct Article: Decodable {
        let slug: String
        let sourcePath: String
        let canonicalUrl: String
        let published: Bool?
        let category: String?
        let heroProduct: String?
        let secondaryHeroProduct: String?
        let locales: [String: LocaleRecord]
        let matchStrings: [String]
    }

    struct LocaleRecord: Decodable {
        let locale: String
        let title: String
        let seoTitle: String?
        let subtitle: String?
        let path: String
        let url: String
    }

    func promptLines(for languageCode: String) -> [String] {
        let records = articles.compactMap { article -> String? in
            guard let localized = article.locales[languageCode] ?? article.locales["en"] else {
                return nil
            }
            let matches = article.matchStrings
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .prefix(5)
                .joined(separator: " | ")
            return "- \(localized.title) -> \(localized.url) [matches: \(matches)]"
        }

        if records.isEmpty {
            return ["- No localized article records available for \(languageCode)."]
        }

        return Array(records.prefix(80))
    }

    func scoped(to rawURL: String?) -> (index: AudioChronicleArticleIndex, matched: Bool) {
        let normalizedNeedles = normalizedURLNeedles(from: rawURL)
        guard !normalizedNeedles.isEmpty else {
            return (AudioChronicleArticleIndex(generatedAt: generatedAt, articleCount: 0, articles: []), false)
        }

        let matches = articles.filter { article in
            let haystack = ([article.slug, article.sourcePath, article.canonicalUrl] + article.matchStrings + article.locales.values.flatMap { [$0.path, $0.url] })
                .flatMap { normalizedURLNeedles(from: $0) }
            return normalizedNeedles.contains { needle in
                haystack.contains(needle) || haystack.contains { $0.contains(needle) || needle.contains($0) }
            }
        }

        return (
            AudioChronicleArticleIndex(generatedAt: generatedAt, articleCount: matches.count, articles: matches),
            !matches.isEmpty
        )
    }

    private func normalizedURLNeedles(from rawValue: String?) -> Set<String> {
        guard let rawValue else {
            return []
        }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return []
        }

        var values: Set<String> = [trimmed.lowercased()]
        if let components = URLComponents(string: trimmed) {
            let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
            if !path.isEmpty {
                values.insert(path)
                values.insert("/\(path)")
                if let slug = path.split(separator: "/").last {
                    values.insert(String(slug))
                }
            }
        } else if let slug = trimmed.split(separator: "/").last {
            values.insert(String(slug).lowercased())
        }

        return values
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
            .filter { !$0.isEmpty }
            .reduce(into: Set<String>()) { $0.insert($1) }
    }
}

private struct SoundbrennerPriceResponse: Decodable {
    let country: String
    let market: String
    let currency: String
    let generatedAt: String?
    let ratesFetchedAt: String?
    let pricesByProductId: [String: ProductPrice]

    struct ProductPrice: Decodable {
        let productId: String?
        let currency: String
        let amount: Double
        let display: String
        let compareAtAmount: Double?
        let compareAtDisplay: String?
        let discountPercentage: Double?
        let marketingAmountOffDisplay: String?
        let source: String?
        let exact: Bool?
        let stale: Bool?
        let fetchedAt: String?
    }

    var promptLines: [String] {
        guard !pricesByProductId.isEmpty else {
            return ["- No product prices returned for \(market)/\(country)."]
        }

        let namesByProductID = [
            "soundbrenner-wave-in-ear-monitors": "Soundbrenner Wave",
            "soundbrenner-wave-pro-in-ear-monitors": "Soundbrenner Wave Pro",
            "soundbrenner-spark-music-practice-companion": "Soundbrenner Spark",
            "soundbrenner-pulse-vibrating-metronome": "Soundbrenner Pulse"
        ]

        return pricesByProductId
            .sorted { $0.key < $1.key }
            .map { productID, price in
                let name = namesByProductID[productID] ?? productID
                let compareAtText = price.compareAtDisplay.map { ", compare-at \( $0 )" } ?? ""
                let discountText = price.discountPercentage.map { ", discount \(Int($0.rounded()))%" } ?? ""
                let amountOffText = (price.marketingAmountOffDisplay ?? price.marketingAmountOffText).map { ", marketing amount-off \($0)" } ?? ""
                return "- \(name): current \(price.display)\(compareAtText)\(discountText)\(amountOffText), currency \(price.currency), source \(price.source ?? "unknown")."
            }
    }

    static func marketingAmountOff(_ amount: Double, currency: String) -> Double {
        let roundedDown: Double
        switch currency {
        case "JPY":
            roundedDown = floor(amount / 1_000) * 1_000
        case "KRW":
            roundedDown = floor(amount / 10_000) * 10_000
        case "USD", "GBP", "EUR", "AUD", "CAD":
            roundedDown = amount >= 100 ? floor(amount / 10) * 10 : floor(amount)
        default:
            roundedDown = amount >= 100 ? floor(amount / 10) * 10 : floor(amount)
        }
        return max(roundedDown, 0)
    }

    private static func marketingAmountOffText(amount: Double, currency: String) -> String? {
        let marketingAmount = marketingAmountOff(amount, currency: currency)
        guard marketingAmount > 0 else {
            return nil
        }
        return "\(Int(marketingAmount.rounded())) \(currency)"
    }
}

private extension SoundbrennerPriceResponse.ProductPrice {
    var marketingAmountOffText: String? {
        guard let compareAtAmount, compareAtAmount > amount else {
            return nil
        }
        return SoundbrennerPriceResponse.marketingAmountOffText(
            amount: compareAtAmount - amount,
            currency: currency
        )
    }
}

private struct ShopifyCredentials {
    var storeDomain: String
    var clientID: String
    var clientSecret: String
    var apiVersion: String

    var normalizedStoreDomain: String {
        storeDomain
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

private final class ShopifyCredentialsStore {
    func read() -> ShopifyCredentials? {
        let storeDomain = readKeychainValue(service: "codex-shopify-store-domain")
        let clientID = readKeychainValue(service: "codex-shopify-client-id")
        let clientSecret = readKeychainValue(service: "codex-shopify-client-secret")
        let apiVersion = readKeychainValue(service: "codex-shopify-api-version")

        guard !storeDomain.isEmpty,
              !clientID.isEmpty,
              !clientSecret.isEmpty else {
            return nil
        }

        return ShopifyCredentials(
            storeDomain: storeDomain,
            clientID: clientID,
            clientSecret: clientSecret,
            apiVersion: apiVersion.isEmpty ? "2026-04" : apiVersion
        )
    }

    private func readKeychainValue(service: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: NSUserName(),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return ""
        }

        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct ShopifyDiscountSnapshot {
    var generatedAt: String?
    var syncedAt: String?
    var sitewidePercentage: Double
    var productPercentagesById: [String: Double]
}

private struct ShopifyProductDefinition {
    var productID: String
    var name: String
    var shopifyProductID: String
}

private struct ShopifyAdminProductPrice {
    var productID: String
    var name: String
    var productLegacyID: String?
    var amount: Double
    var currency: String
    var compareAtAmount: Double?
}

private struct ShopifyGraphQLRequest: Encodable {
    var query: String
    var variables: [String: String]?
}

private struct ShopifyOAuthResponse: Decodable {
    var accessToken: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
    }
}

private struct ShopifyGraphQLResponse<T: Decodable>: Decodable {
    var data: T?
    var errors: [ShopifyGraphQLError]?
}

private struct ShopifyGraphQLError: Decodable {
    var message: String
}

private struct ShopifyProductPriceData: Decodable {
    var product: Product?

    struct Product: Decodable {
        var legacyResourceId: String?
        var variants: VariantConnection
    }

    struct VariantConnection: Decodable {
        var nodes: [Variant]
    }

    struct Variant: Decodable {
        var price: String?
        var compareAtPrice: String?
        var contextualPricing: ContextualPricing?
    }

    struct ContextualPricing: Decodable {
        var price: Money?
        var compareAtPrice: Money?
    }

    struct Money: Decodable {
        var amount: String
        var currencyCode: String
    }
}

private struct ShopifyDiscountSnapshotData: Decodable {
    var metaobjectByHandle: Metaobject?

    struct Metaobject: Decodable {
        var fields: [Field]
    }

    struct Field: Decodable {
        var key: String
        var value: String?
    }
}

private struct ShopifyComponentPriceData: Decodable {
    var products: ProductConnection

    struct ProductConnection: Decodable {
        var nodes: [Product]
    }

    struct Product: Decodable {
        var title: String
        var variants: VariantConnection
    }

    struct VariantConnection: Decodable {
        var nodes: [Variant]
    }

    struct Variant: Decodable {
        var title: String
        var price: String?
        var contextualPricing: ContextualPricing?
    }

    struct ContextualPricing: Decodable {
        var price: Money?
    }

    struct Money: Decodable {
        var amount: String
        var currencyCode: String
    }
}

private struct ShopifyShippingInfoData: Decodable {
    var metaobjectByHandle: Metaobject?

    struct Metaobject: Decodable {
        var fields: [Field]
    }

    struct Field: Decodable {
        var key: String
        var value: String?
    }
}

private final class ShopifyAdminPricingService {
    private let credentials: ShopifyCredentials
    private var cachedAccessToken: String?

    init(credentials: ShopifyCredentials) {
        self.credentials = credentials
    }

    func fetchPrices(for market: AdLocalizationLanguage, products: [ShopifyProductDefinition]) async throws -> SoundbrennerPriceResponse {
        let discountSnapshot = try? await fetchDiscountSnapshot()
        var rows: [String: SoundbrennerPriceResponse.ProductPrice] = [:]

        for product in products {
            let adminPrice = try await fetchProductPrice(product: product, countryCode: market.countryCode)
            let discounted = applyDiscountSnapshot(to: adminPrice, snapshot: discountSnapshot)
            rows[product.productID] = SoundbrennerPriceResponse.ProductPrice(
                productId: product.productID,
                currency: discounted.currency,
                amount: roundAmount(discounted.amount, currency: discounted.currency),
                display: formatAmount(discounted.amount, currency: discounted.currency, localeIdentifier: localeIdentifier(for: market)),
                compareAtAmount: discounted.compareAtAmount.map { roundAmount($0, currency: discounted.currency) },
                compareAtDisplay: discounted.compareAtAmount.map {
                    formatAmount($0, currency: discounted.currency, localeIdentifier: localeIdentifier(for: market))
                },
                discountPercentage: discountPercentage(current: discounted.amount, compareAt: discounted.compareAtAmount),
                marketingAmountOffDisplay: marketingAmountOffDisplay(
                    current: discounted.amount,
                    compareAt: discounted.compareAtAmount,
                    currency: discounted.currency,
                    localeIdentifier: localeIdentifier(for: market)
                ),
                source: "shopify-admin",
                exact: true,
                stale: false,
                fetchedAt: ISO8601DateFormatter().string(from: .now)
            )
        }

        return SoundbrennerPriceResponse(
            country: market.countryCode,
            market: market.marketCode,
            currency: market.currencyCode,
            generatedAt: ISO8601DateFormatter().string(from: .now),
            ratesFetchedAt: nil,
            pricesByProductId: rows
        )
    }

    func fetchShippingInfo(for market: AdLocalizationLanguage) async throws -> AdLocalizationShippingInfo {
        let countryHandle = market.countryCode.lowercased()
        let data = try await graphql(
            """
            query ShippingInfo {
              metaobjectByHandle(handle: { type: "database_localized_shipping_info", handle: "\(countryHandle)" }) {
                fields {
                  key
                  value
                }
              }
            }
            """,
            as: ShopifyShippingInfoData.self
        )

        guard let fields = data.metaobjectByHandle?.fields else {
            throw AppError.invalidResponse
        }

        let fieldMap = Dictionary(uniqueKeysWithValues: fields.map { ($0.key, $0.value ?? "") })
        return AdLocalizationShippingInfo(
            countryCode: market.countryCode,
            shipsToCountry: booleanValue(fieldMap["ship_to_it"], defaultValue: true),
            hasFreeShipping: booleanValue(fieldMap["free_shipping_available"], defaultValue: false),
            threshold: fieldMap["free_shipping_threshold_in_local_currency"].flatMap(Double.init),
            currency: market.currencyCode,
            advertisedMinTime: fieldMap["advertised_min_time"],
            advertisedMaxTime: fieldMap["advertised_max_time"]
        )
    }

    func fetchDiscountInfo(products: [ShopifyProductDefinition]) async throws -> AdLocalizationDiscountInfo {
        let snapshot = try await fetchDiscountSnapshot()
        let sitewidePercentage = normalizedPercentage(snapshot.sitewidePercentage)
        var maxPercentage = sitewidePercentage
        var maxProductName: String?

        for product in products {
            let productPercentage = normalizedPercentage(snapshot.productPercentagesById[product.shopifyProductID] ?? 0)
            let combinedPercentage = (1 - ((1 - sitewidePercentage / 100) * (1 - productPercentage / 100))) * 100
            if combinedPercentage > maxPercentage {
                maxPercentage = combinedPercentage
                maxProductName = product.name
            }
        }

        return AdLocalizationDiscountInfo(
            sitewidePercentage: sitewidePercentage,
            maxAdvertisedPercentage: maxPercentage,
            maxAdvertisedProductName: maxProductName,
            generatedAt: snapshot.generatedAt,
            syncedAt: snapshot.syncedAt
        )
    }

    func fetchComponentPriceMatches(for market: AdLocalizationLanguage) async throws -> [AdLocalizationComponentPriceMatch] {
        let data = try await graphql(
            """
            query ComponentPriceMatches($country: CountryCode!) {
              products(first: 100, query: "status:active") {
                nodes {
                  title
                  variants(first: 10) {
                    nodes {
                      title
                      price
                      contextualPricing(context: { country: $country }) {
                        price {
                          amount
                          currencyCode
                        }
                      }
                    }
                  }
                }
              }
            }
            """,
            variables: ["country": market.countryCode],
            as: ShopifyComponentPriceData.self
        )

        struct Candidate {
            var targetAmount: Double
            var currency: String
            var title: String
        }

        var candidatesByUSDPrice: [Int: [Candidate]] = [:]
        for product in data.products.nodes {
            for variant in product.variants.nodes {
                guard let rawUSDPrice = variant.price,
                      let usdAmount = Double(rawUSDPrice),
                      let targetPrice = variant.contextualPricing?.price,
                      let targetAmount = Double(targetPrice.amount),
                      usdAmount > 0 else {
                    continue
                }
                let key = Int((usdAmount * 100).rounded())
                let title = variant.title == "Default Title" ? product.title : "\(product.title) - \(variant.title)"
                candidatesByUSDPrice[key, default: []].append(Candidate(
                    targetAmount: targetAmount,
                    currency: targetPrice.currencyCode,
                    title: title
                ))
            }
        }

        return candidatesByUSDPrice
            .compactMap { key, candidates -> AdLocalizationComponentPriceMatch? in
                guard let firstCandidate = candidates.sorted(by: { $0.title.localizedStandardCompare($1.title) == .orderedAscending }).first else {
                    return nil
                }
                let usdAmount = Double(key) / 100
                return AdLocalizationComponentPriceMatch(
                    sourceUSDDisplay: formatAmount(usdAmount, currency: "USD", localeIdentifier: "en_US"),
                    targetDisplay: formatAmount(firstCandidate.targetAmount, currency: firstCandidate.currency, localeIdentifier: market.localeIdentifier),
                    exampleTitles: Array(Set(candidates.map(\.title))).sorted()
                )
            }
            .sorted { $0.sourceUSDDisplay.localizedStandardCompare($1.sourceUSDDisplay) == .orderedAscending }
    }

    private func fetchAccessToken() async throws -> String {
        if let cachedAccessToken {
            return cachedAccessToken
        }

        let url = URL(string: "https://\(credentials.normalizedStoreDomain)/admin/oauth/access_token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formURLEncodedBody([
            "grant_type": "client_credentials",
            "client_id": credentials.clientID,
            "client_secret": credentials.clientSecret
        ])
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw AppError.apiError("Shopify OAuth failed.")
        }

        let payload = try JSONDecoder().decode(ShopifyOAuthResponse.self, from: data)
        cachedAccessToken = payload.accessToken
        return payload.accessToken
    }

    private func graphql<T: Decodable>(_ query: String, variables: [String: String]? = nil, as type: T.Type) async throws -> T {
        let endpoint = URL(string: "https://\(credentials.normalizedStoreDomain)/admin/api/\(credentials.apiVersion)/graphql.json")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(try await fetchAccessToken(), forHTTPHeaderField: "X-Shopify-Access-Token")
        request.httpBody = try JSONEncoder().encode(ShopifyGraphQLRequest(query: query, variables: variables))
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw AppError.apiError("Shopify GraphQL request failed.")
        }

        let payload = try JSONDecoder().decode(ShopifyGraphQLResponse<T>.self, from: data)
        if let message = payload.errors?.map(\.message).joined(separator: "; "), !message.isEmpty {
            throw AppError.apiError(message)
        }
        guard let data = payload.data else {
            throw AppError.invalidResponse
        }
        return data
    }

    private func fetchProductPrice(product: ShopifyProductDefinition, countryCode: String) async throws -> ShopifyAdminProductPrice {
        let data = try await graphql(
            """
            query ProductPrice($id: ID!, $country: CountryCode!) {
              product(id: $id) {
                legacyResourceId
                variants(first: 1) {
                  nodes {
                    price
                    compareAtPrice
                    contextualPricing(context: { country: $country }) {
                      price {
                        amount
                        currencyCode
                      }
                      compareAtPrice {
                        amount
                        currencyCode
                      }
                    }
                  }
                }
              }
            }
            """,
            variables: [
                "id": "gid://shopify/Product/\(product.shopifyProductID)",
                "country": countryCode
            ],
            as: ShopifyProductPriceData.self
        )

        guard let node = data.product?.variants.nodes.first else {
            throw AppError.invalidResponse
        }

        if let contextualPrice = node.contextualPricing?.price,
           let amount = Double(contextualPrice.amount) {
            let compareAtAmount = node.contextualPricing?.compareAtPrice.flatMap { Double($0.amount) }
            return ShopifyAdminProductPrice(
                productID: product.productID,
                name: product.name,
                productLegacyID: data.product?.legacyResourceId,
                amount: amount,
                currency: contextualPrice.currencyCode,
                compareAtAmount: compareAtAmount
            )
        }

        guard let rawPrice = node.price,
              let amount = Double(rawPrice) else {
            throw AppError.invalidResponse
        }

        return ShopifyAdminProductPrice(
            productID: product.productID,
            name: product.name,
            productLegacyID: data.product?.legacyResourceId,
            amount: amount,
            currency: "USD",
            compareAtAmount: node.compareAtPrice.flatMap(Double.init)
        )
    }

    private func fetchDiscountSnapshot() async throws -> ShopifyDiscountSnapshot {
        let data = try await graphql(
            """
            query DiscountSnapshot {
              metaobjectByHandle(handle: { type: "storefront_discount_snapshot", handle: "current" }) {
                fields {
                  key
                  value
                }
              }
            }
            """,
            as: ShopifyDiscountSnapshotData.self
        )

        guard let fields = data.metaobjectByHandle?.fields else {
            throw AppError.invalidResponse
        }

        let fieldMap = Dictionary(uniqueKeysWithValues: fields.map { ($0.key, $0.value ?? "") })
        let rawPayload = fieldMap["payload"] ?? "{}"
        let payloadData = Data(rawPayload.utf8)
        let payload = (try? JSONSerialization.jsonObject(with: payloadData)) as? [String: Any] ?? [:]
        let productPercentages = (payload["productPercentagesById"] as? [String: Any] ?? [:]).reduce(into: [String: Double]()) { result, entry in
            result[entry.key] = numericValue(entry.value)
        }

        return ShopifyDiscountSnapshot(
            generatedAt: payload["generatedAt"] as? String,
            syncedAt: fieldMap["synced_at"],
            sitewidePercentage: numericValue(payload["sitewidePercentage"]),
            productPercentagesById: productPercentages
        )
    }

    private func applyDiscountSnapshot(to price: ShopifyAdminProductPrice, snapshot: ShopifyDiscountSnapshot?) -> ShopifyAdminProductPrice {
        guard let snapshot,
              let productLegacyID = price.productLegacyID else {
            return price
        }

        let sitewideFraction = normalizedPercentage(snapshot.sitewidePercentage) / 100
        let productFraction = normalizedPercentage(snapshot.productPercentagesById[productLegacyID] ?? 0) / 100
        let combinedDiscountFraction = 1 - ((1 - sitewideFraction) * (1 - productFraction))
        guard combinedDiscountFraction > 0 else {
            return price
        }

        return ShopifyAdminProductPrice(
            productID: price.productID,
            name: price.name,
            productLegacyID: price.productLegacyID,
            amount: price.amount * (1 - combinedDiscountFraction),
            currency: price.currency,
            compareAtAmount: price.amount
        )
    }

    private func formatAmount(_ amount: Double, currency: String, localeIdentifier: String) -> String {
        let roundedAmount = roundAmount(amount, currency: currency)
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.maximumFractionDigits = 0
        formatter.locale = Locale(identifier: localeIdentifier)
        let display = formatter.string(from: NSNumber(value: roundedAmount)) ?? "\(currency) \(Int(roundedAmount))"

        switch currency {
        case "AUD" where display.contains("$") && !display.contains("A$") && !display.contains("AU$"):
            return display.replacingOccurrences(of: "$", with: "AU$")
        case "CAD" where display.contains("$") && !display.contains("CA$"):
            return display.replacingOccurrences(of: "$", with: "CA$")
        default:
            return display
        }
    }

    private func roundAmount(_ amount: Double, currency: String) -> Double {
        switch currency {
        case "JPY":
            max(100, (amount / 100).rounded() * 100)
        case "KRW":
            max(1_000, (amount / 1_000).rounded() * 1_000)
        default:
            amount.rounded()
        }
    }

    private func discountPercentage(current: Double, compareAt: Double?) -> Double? {
        guard let compareAt, compareAt > current else {
            return nil
        }
        return ((compareAt - current) / compareAt * 10000).rounded() / 100
    }

    private func marketingAmountOffDisplay(current: Double, compareAt: Double?, currency: String, localeIdentifier: String) -> String? {
        guard let compareAt, compareAt > current else {
            return nil
        }
        let amount = SoundbrennerPriceResponse.marketingAmountOff(compareAt - current, currency: currency)
        guard amount > 0 else {
            return nil
        }
        return formatAmount(amount, currency: currency, localeIdentifier: localeIdentifier)
    }

    private func localeIdentifier(for market: AdLocalizationLanguage) -> String {
        market.localeIdentifier
    }

    private func normalizedPercentage(_ value: Double) -> Double {
        min(max(value, 0), 100)
    }
}

private func booleanValue(_ value: String?, defaultValue: Bool) -> Bool {
    guard let value else {
        return defaultValue
    }
    switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "true", "1", "yes":
        return true
    case "false", "0", "no":
        return false
    default:
        return defaultValue
    }
}

private func numericValue(_ value: Any?) -> Double {
    switch value {
    case let number as NSNumber:
        number.doubleValue
    case let number as Double:
        number
    case let number as Int:
        Double(number)
    case let string as String:
        Double(string) ?? 0
    default:
        0
    }
}

private func formURLEncodedBody(_ values: [String: String]) -> Data {
    var components = URLComponents()
    components.queryItems = values.map { URLQueryItem(name: $0.key, value: $0.value) }
    return Data((components.percentEncodedQuery ?? "").utf8)
}

@MainActor
private final class AdLocalizationTruthService {
    private let articleIndexURL = URL(string: "https://www.audiochronicle.com/data/article-localization-index.json")!
    private let priceAPIURL = URL(string: "https://www.audiochronicle.com/api/prices")!
    private let credentialsStore = ShopifyCredentialsStore()
    func fetch(
        for markets: Set<AdLocalizationLanguage>,
        product: AdLocalizationProduct,
        audioChronicleURL: String?
    ) async throws -> AdLocalizationTruthPacket {
        let articleScope = try await fetchArticleIndex().scoped(to: audioChronicleURL)
        let shopifyPayload = try await fetchShopifyPayload(for: markets, product: product)
        let prices = product == .none || !shopifyPayload.prices.isEmpty
            ? shopifyPayload.prices
            : try await fetchPricesFromAudioChronicle(for: markets, product: product)
        return AdLocalizationTruthPacket(
            fetchedAt: .now,
            selectedProduct: product,
            articleURL: normalizedOptionalString(audioChronicleURL),
            articleURLMatched: articleScope.matched,
            articles: articleScope.index,
            pricesByMarket: prices,
            discountByMarket: shopifyPayload.discounts,
            componentPriceMatchesByMarket: shopifyPayload.componentPriceMatches,
            shippingByMarket: shopifyPayload.shipping
        )
    }

    private func fetchArticleIndex() async throws -> AudioChronicleArticleIndex {
        let (data, response) = try await URLSession.shared.data(from: articleIndexURL)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw AppError.apiError("Audio Chronicle article index could not be fetched.")
        }
        return try JSONDecoder().decode(AudioChronicleArticleIndex.self, from: data)
    }

    private func fetchShopifyPayload(
        for markets: Set<AdLocalizationLanguage>,
        product: AdLocalizationProduct
    ) async throws -> (
        prices: [AdLocalizationLanguage: SoundbrennerPriceResponse],
        discounts: [AdLocalizationLanguage: AdLocalizationDiscountInfo],
        componentPriceMatches: [AdLocalizationLanguage: [AdLocalizationComponentPriceMatch]],
        shipping: [AdLocalizationLanguage: AdLocalizationShippingInfo]
    ) {
        if let credentials = credentialsStore.read() {
            let shopifyService = ShopifyAdminPricingService(credentials: credentials)
            let selectedProduct = product == .none ? nil : shopifyDefinition(for: product)
            let discountInfo = try? await shopifyService.fetchDiscountInfo(products: allShopifyDefinitions())
            var directResults: [AdLocalizationLanguage: SoundbrennerPriceResponse] = [:]
            var discountResults: [AdLocalizationLanguage: AdLocalizationDiscountInfo] = [:]
            var componentPriceMatchResults: [AdLocalizationLanguage: [AdLocalizationComponentPriceMatch]] = [:]
            var shippingResults: [AdLocalizationLanguage: AdLocalizationShippingInfo] = [:]
            var shouldFallback = false

            for market in markets {
                do {
                    if let selectedProduct {
                        directResults[market] = try await shopifyService.fetchPrices(for: market, products: [selectedProduct])
                    }
                    if let discountInfo {
                        discountResults[market] = discountInfo
                    }
                    componentPriceMatchResults[market] = try? await shopifyService.fetchComponentPriceMatches(for: market)
                    shippingResults[market] = try? await shopifyService.fetchShippingInfo(for: market)
                } catch {
                    shouldFallback = true
                    break
                }
            }

            if !shouldFallback, selectedProduct == nil || !directResults.isEmpty {
                return (directResults, discountResults, componentPriceMatchResults, shippingResults)
            }
        }

        return ([:], [:], [:], [:])
    }

    private func fetchPricesFromAudioChronicle(
        for markets: Set<AdLocalizationLanguage>,
        product: AdLocalizationProduct
    ) async throws -> [AdLocalizationLanguage: SoundbrennerPriceResponse] {
        var results: [AdLocalizationLanguage: SoundbrennerPriceResponse] = [:]
        for market in markets {
            var components = URLComponents(url: priceAPIURL, resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "products", value: product.productID),
                URLQueryItem(name: "country", value: market.countryCode)
            ]
            guard let url = components.url else {
                continue
            }

            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                continue
            }
            results[market] = try JSONDecoder().decode(SoundbrennerPriceResponse.self, from: data)
        }
        return results
    }

    private func shopifyDefinition(for product: AdLocalizationProduct) -> ShopifyProductDefinition {
        ShopifyProductDefinition(
            productID: product.productID,
            name: product.productName,
            shopifyProductID: product.shopifyProductID
        )
    }

    private func allShopifyDefinitions() -> [ShopifyProductDefinition] {
        AdLocalizationProduct.allCases
            .filter { $0 != .none }
            .map(shopifyDefinition(for:))
    }

    private func normalizedOptionalString(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

@MainActor
final class GalleryStore: ObservableObject {
    @Published private(set) var jobs: [GenerationJob] = []

    private let fileManager = FileManager.default
    private let metadataURL: URL
    private let pendingMetadataURL: URL
    private let imagesDirectoryURL: URL
    private let imageCache = NSCache<NSString, NSImage>()

    init() {
        let baseURL = Self.appSupportDirectory()
        self.imagesDirectoryURL = baseURL.appendingPathComponent("Images", isDirectory: true)
        self.metadataURL = baseURL.appendingPathComponent("jobs.json")
        self.pendingMetadataURL = baseURL.appendingPathComponent("pending-jobs.json")

        do {
            try fileManager.createDirectory(at: imagesDirectoryURL, withIntermediateDirectories: true)
            jobs = try loadJobs()
            try recoverInterruptedPendingJobs()
        } catch {
            jobs = []
        }
    }

    func addJob(
        form: GenerationForm,
        inputPrompt: String,
        payloads: [GeneratedImagePayload],
        referenceImageCount: Int,
        randomModelMode: RandomModelMode,
        randomPresetCategories: [PromptPresetCategory],
        modelNames: [String],
        modelSnapshots: [GenerationModelSnapshot],
        cameraSnapshot: GenerationCameraSnapshot?,
        presetSnapshots: [GenerationPresetSnapshot],
        productSnapshot: GenerationProductSnapshot?,
        adAngleSnapshot: GenerationAdAngleSnapshot?,
        randomAdAngle: Bool,
        promotionalContextSnapshot: GenerationPromotionalContextSnapshot?,
        promotionalContextSnapshots: [GenerationPromotionalContextSnapshot] = [],
        randomPromotionalContext: Bool,
        referenceImages: [GenerationReferenceImageSnapshot],
        userReferenceImages: [GenerationReferenceImageSnapshot]
    ) throws -> GenerationJob {
        let savedImages = try payloads.enumerated().map { index, payload in
            let fileName = "\(UUID().uuidString)-\(index + 1).\(payload.format.rawValue)"
            let destination = imagesDirectoryURL.appendingPathComponent(fileName)
            try payload.data.write(to: destination, options: .atomic)
            return GalleryImage(fileName: fileName, format: payload.format)
        }

        let job = GenerationJob(
            inputPrompt: inputPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
            prompt: form.prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            shotMode: form.shotMode,
            audience: form.audience,
            imageModel: form.imageModel,
            quality: form.quality,
            resolution: form.resolution,
            geminiAspectRatio: form.geminiAspectRatio,
            geminiImageSize: form.geminiImageSize,
            imageCount: form.sanitizedImageCount,
            outputFormat: form.outputFormat,
            moderation: form.moderation,
            referenceImageCount: referenceImageCount,
            randomModelMode: randomModelMode,
            randomPresetCategories: randomPresetCategories,
            modelNames: modelNames,
            modelSnapshots: modelSnapshots,
            cameraSnapshot: cameraSnapshot,
            presetSnapshots: presetSnapshots,
            productSnapshot: productSnapshot,
            adAngleSnapshot: adAngleSnapshot,
            randomAdAngle: randomAdAngle,
            promotionalContextSnapshot: promotionalContextSnapshot,
            promotionalContextSnapshots: promotionalContextSnapshots,
            randomPromotionalContext: randomPromotionalContext,
            referenceImages: referenceImages,
            userReferenceImages: userReferenceImages,
            images: savedImages
        )

        jobs.insert(job, at: 0)
        try persist()
        return job
    }

    func addFailedJob(
        form: GenerationForm,
        inputPrompt: String,
        failureMessage: String,
        referenceImageCount: Int,
        randomModelMode: RandomModelMode,
        randomPresetCategories: [PromptPresetCategory],
        modelNames: [String],
        modelSnapshots: [GenerationModelSnapshot],
        cameraSnapshot: GenerationCameraSnapshot?,
        presetSnapshots: [GenerationPresetSnapshot],
        productSnapshot: GenerationProductSnapshot?,
        adAngleSnapshot: GenerationAdAngleSnapshot?,
        randomAdAngle: Bool,
        promotionalContextSnapshot: GenerationPromotionalContextSnapshot?,
        promotionalContextSnapshots: [GenerationPromotionalContextSnapshot] = [],
        randomPromotionalContext: Bool,
        referenceImages: [GenerationReferenceImageSnapshot],
        userReferenceImages: [GenerationReferenceImageSnapshot]
    ) throws -> GenerationJob {
        let job = GenerationJob(
            inputPrompt: inputPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
            prompt: form.prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            shotMode: form.shotMode,
            audience: form.audience,
            imageModel: form.imageModel,
            quality: form.quality,
            resolution: form.resolution,
            geminiAspectRatio: form.geminiAspectRatio,
            geminiImageSize: form.geminiImageSize,
            imageCount: form.sanitizedImageCount,
            outputFormat: form.outputFormat,
            moderation: form.moderation,
            referenceImageCount: referenceImageCount,
            randomModelMode: randomModelMode,
            randomPresetCategories: randomPresetCategories,
            modelNames: modelNames,
            modelSnapshots: modelSnapshots,
            cameraSnapshot: cameraSnapshot,
            presetSnapshots: presetSnapshots,
            productSnapshot: productSnapshot,
            adAngleSnapshot: adAngleSnapshot,
            randomAdAngle: randomAdAngle,
            promotionalContextSnapshot: promotionalContextSnapshot,
            promotionalContextSnapshots: promotionalContextSnapshots,
            randomPromotionalContext: randomPromotionalContext,
            referenceImages: referenceImages,
            userReferenceImages: userReferenceImages,
            images: [],
            failureMessage: failureMessage
        )

        jobs.insert(job, at: 0)
        try persist()
        return job
    }

    func imageURL(for image: GalleryImage) -> URL {
        imagesDirectoryURL.appendingPathComponent(image.fileName)
    }

    func imageData(for image: GalleryImage) -> Data? {
        try? Data(contentsOf: imageURL(for: image))
    }

    func cachedImage(for image: GalleryImage) -> NSImage? {
        let cacheKey = image.fileName as NSString
        if let cachedImage = imageCache.object(forKey: cacheKey) {
            return cachedImage
        }

        guard let data = imageData(for: image),
              let image = NSImage(data: data) else {
            return nil
        }

        imageCache.setObject(image, forKey: cacheKey)
        return image
    }

    func export(image: GalleryImage) throws -> URL {
        let downloadsURL = try fileManager.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let sourceURL = imageURL(for: image)
        let destinationURL = uniqueExportURL(in: downloadsURL, preferredName: image.fileName)
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }

    func export(job: GenerationJob) throws -> [URL] {
        try job.images.map(export(image:))
    }

    func delete(image: GalleryImage, from job: GenerationJob) throws {
        let imageURL = imageURL(for: image)
        if fileManager.fileExists(atPath: imageURL.path) {
            try fileManager.removeItem(at: imageURL)
        }
        imageCache.removeObject(forKey: image.fileName as NSString)

        guard let index = jobs.firstIndex(where: { $0.id == job.id }) else {
            return
        }

        var updatedImages = jobs[index].images
        updatedImages.removeAll { $0.id == image.id }

        if updatedImages.isEmpty {
            jobs.remove(at: index)
        } else {
            let existing = jobs[index]
            jobs[index] = GenerationJob(
                id: existing.id,
                createdAt: existing.createdAt,
                inputPrompt: existing.inputPrompt,
                prompt: existing.prompt,
                shotMode: existing.shotMode,
                audience: existing.audience,
                imageModel: existing.imageModel,
                quality: existing.quality,
                resolution: existing.resolution,
                geminiAspectRatio: existing.geminiAspectRatio,
                geminiImageSize: existing.geminiImageSize,
                imageCount: updatedImages.count,
                outputFormat: existing.outputFormat,
                moderation: existing.moderation,
                referenceImageCount: existing.referenceImageCount,
                randomModelMode: existing.randomModelMode,
                randomPresetCategories: existing.randomPresetCategories,
                modelNames: existing.modelNames,
                modelSnapshots: existing.modelSnapshots,
                cameraSnapshot: existing.cameraSnapshot,
                presetSnapshots: existing.presetSnapshots,
                productSnapshot: existing.productSnapshot,
                adAngleSnapshot: existing.adAngleSnapshot,
                randomAdAngle: existing.randomAdAngle,
                promotionalContextSnapshot: existing.promotionalContextSnapshot,
                promotionalContextSnapshots: existing.promotionalContextSnapshots,
                randomPromotionalContext: existing.randomPromotionalContext,
                referenceImages: existing.referenceImages,
                userReferenceImages: existing.userReferenceImages,
                images: updatedImages,
                failureMessage: existing.failureMessage
            )
        }

        try persist()
    }

    func delete(job: GenerationJob) throws {
        for image in job.images {
            let imageURL = imageURL(for: image)
            if fileManager.fileExists(atPath: imageURL.path) {
                try fileManager.removeItem(at: imageURL)
            }
            imageCache.removeObject(forKey: image.fileName as NSString)
        }

        jobs.removeAll { $0.id == job.id }
        try persist()
    }

    func addPendingRecord(
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
        adAngleSnapshot: GenerationAdAngleSnapshot?,
        randomAdAngle: Bool,
        promotionalContextSnapshot: GenerationPromotionalContextSnapshot?,
        promotionalContextSnapshots: [GenerationPromotionalContextSnapshot] = [],
        randomPromotionalContext: Bool,
        referenceImages: [GenerationReferenceImageSnapshot],
        userReferenceImages: [GenerationReferenceImageSnapshot]
    ) throws {
        let record = PendingGenerationRecord(
            id: id,
            form: form,
            inputPrompt: inputPrompt,
            referenceImageCount: referenceImageCount,
            randomModelMode: randomModelMode,
            randomPresetCategories: randomPresetCategories,
            modelNames: modelNames,
            modelSnapshots: modelSnapshots,
            cameraSnapshot: cameraSnapshot,
            presetSnapshots: presetSnapshots,
            productSnapshot: productSnapshot,
            adAngleSnapshot: adAngleSnapshot,
            randomAdAngle: randomAdAngle,
            promotionalContextSnapshot: promotionalContextSnapshot,
            promotionalContextSnapshots: promotionalContextSnapshots,
            randomPromotionalContext: randomPromotionalContext,
            referenceImages: referenceImages,
            userReferenceImages: userReferenceImages
        )

        var records = try loadPendingRecords()
        records.removeAll { $0.id == id }
        records.insert(record, at: 0)
        try persistPendingRecords(records)
    }

    func removePendingRecord(id: UUID) throws {
        var records = try loadPendingRecords()
        records.removeAll { $0.id == id }
        try persistPendingRecords(records)
    }

    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(jobs)
        try data.write(to: metadataURL, options: .atomic)
    }

    private func persistPendingRecords(_ records: [PendingGenerationRecord]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(records)
        try data.write(to: pendingMetadataURL, options: .atomic)
    }

    private func loadJobs() throws -> [GenerationJob] {
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            return []
        }

        let data = try Data(contentsOf: metadataURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([GenerationJob].self, from: data)
    }

    private func loadPendingRecords() throws -> [PendingGenerationRecord] {
        guard fileManager.fileExists(atPath: pendingMetadataURL.path) else {
            return []
        }

        let data = try Data(contentsOf: pendingMetadataURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([PendingGenerationRecord].self, from: data)
    }

    private func recoverInterruptedPendingJobs() throws {
        let records = try loadPendingRecords()
        guard !records.isEmpty else {
            return
        }

        let recoveredJobs = records.map { record in
            GenerationJob(
                id: record.id,
                inputPrompt: record.inputPrompt,
                prompt: record.form.prompt,
                shotMode: record.form.shotMode,
                audience: record.form.audience,
                imageModel: record.form.imageModel,
                quality: record.form.quality,
                resolution: record.form.resolution,
                geminiAspectRatio: record.form.geminiAspectRatio,
                geminiImageSize: record.form.geminiImageSize,
                imageCount: record.form.sanitizedImageCount,
                outputFormat: record.form.outputFormat,
                moderation: record.form.moderation,
                referenceImageCount: record.referenceImageCount,
                randomModelMode: record.randomModelMode,
                randomPresetCategories: record.randomPresetCategories,
                modelNames: record.modelNames,
                modelSnapshots: record.modelSnapshots,
                cameraSnapshot: record.cameraSnapshot,
                presetSnapshots: record.presetSnapshots,
                productSnapshot: record.productSnapshot,
                adAngleSnapshot: record.adAngleSnapshot,
                randomAdAngle: record.randomAdAngle,
                promotionalContextSnapshot: record.promotionalContextSnapshot,
                promotionalContextSnapshots: record.promotionalContextSnapshots,
                randomPromotionalContext: record.randomPromotionalContext,
                referenceImages: record.referenceImages,
                userReferenceImages: record.userReferenceImages,
                images: [],
                failureMessage: "Generation was interrupted because the app quit or relaunched before the request finished."
            )
        }

        jobs.insert(contentsOf: recoveredJobs, at: 0)
        try persist()
        try persistPendingRecords([])
    }

    private func uniqueExportURL(in directory: URL, preferredName: String) -> URL {
        let baseName = (preferredName as NSString).deletingPathExtension
        let ext = (preferredName as NSString).pathExtension
        var candidate = directory.appendingPathComponent(preferredName)
        var index = 2

        while fileManager.fileExists(atPath: candidate.path) {
            let fileName = "\(baseName)-\(index).\(ext)"
            candidate = directory.appendingPathComponent(fileName)
            index += 1
        }

        return candidate
    }

    private static func appSupportDirectory() -> URL {
        let fileManager = FileManager.default
        let base = try! fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = base.appendingPathComponent("SoundbrennerMediaGenerator", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

@MainActor
enum SharedProfileStorage {
    private static let sharedFolderBookmarkKey = "sharedImageGenerationFolderBookmark"

    static func modelsDirectory(fileManager: FileManager = .default) -> URL {
        if let sharedDirectory = sharedImageGenerationDirectory(fileManager: fileManager) {
            return sharedDirectory.appendingPathComponent("models", isDirectory: true)
        }

        return legacyModelsDirectory(fileManager: fileManager)
    }

    static func camerasDirectory(fileManager: FileManager = .default) -> URL {
        // Legacy style profiles are no longer part of the shared creative-layer system.
        return legacyCamerasDirectory(fileManager: fileManager)
    }

    static func productsDirectory(fileManager: FileManager = .default) -> URL {
        if let sharedDirectory = sharedImageGenerationDirectory(fileManager: fileManager) {
            return sharedDirectory.appendingPathComponent("products", isDirectory: true)
        }

        let base = try! fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base.appendingPathComponent("SoundbrennerMediaGeneratorProducts", isDirectory: true)
    }

    static func adAnglesDirectory(fileManager: FileManager = .default) -> URL {
        if let sharedDirectory = sharedImageGenerationDirectory(fileManager: fileManager) {
            return sharedDirectory.appendingPathComponent("ad angles", isDirectory: true)
        }

        let base = try! fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base.appendingPathComponent("SoundbrennerMediaGeneratorAdAngles", isDirectory: true)
    }

    static func promotionalContextsDirectory(fileManager: FileManager = .default) -> URL {
        if let sharedDirectory = sharedImageGenerationDirectory(fileManager: fileManager) {
            return sharedDirectory.appendingPathComponent("promotional contexts", isDirectory: true)
        }

        let base = try! fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base.appendingPathComponent("SoundbrennerMediaGeneratorPromotionalContexts", isDirectory: true)
    }

    static func promptPresetDirectory(for category: PromptPresetCategory, fileManager: FileManager = .default) -> URL {
        promptPresetDirectory(named: category.folderName, fileManager: fileManager)
    }

    static func promptPresetDirectory(named folderName: String, fileManager: FileManager = .default) -> URL {
        if let sharedDirectory = sharedImageGenerationDirectory(fileManager: fileManager) {
            return sharedDirectory.appendingPathComponent(folderName, isDirectory: true)
        }

        let base = try! fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base
            .appendingPathComponent("SoundbrennerMediaGeneratorPromptPresets", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    static func legacyModelsDirectory(fileManager: FileManager = .default) -> URL {
        let base = try! fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base.appendingPathComponent("SoundbrennerMediaGeneratorModels", isDirectory: true)
    }

    static func legacyCamerasDirectory(fileManager: FileManager = .default) -> URL {
        let base = try! fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base.appendingPathComponent("SoundbrennerMediaGeneratorCameraProfiles", isDirectory: true)
    }

    static func statusText(fileManager: FileManager = .default) -> String {
        if let directory = sharedImageGenerationDirectory(fileManager: fileManager) {
            return "Using shared Dropbox storage: \(directory.path)"
        }

        return "Using local app storage. Choose the Dropbox image generation folder once to sync models, products, and creative presets."
    }

    static func authorizeSharedFolder(fileManager: FileManager = .default) throws {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the Dropbox image generation folder, or the LLM context folder that contains marketing/image generation."
        panel.prompt = "Use Folder"

        if let defaultURL = defaultSharedImageGenerationDirectory(fileManager: fileManager) {
            panel.directoryURL = defaultURL.deletingLastPathComponent()
        }

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return
        }

        let imageGenerationDirectory = normalizedImageGenerationDirectory(from: selectedURL, fileManager: fileManager)
        try fileManager.createDirectory(
            at: imageGenerationDirectory.appendingPathComponent("models", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: imageGenerationDirectory.appendingPathComponent("products", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: imageGenerationDirectory.appendingPathComponent("ad angles", isDirectory: true),
            withIntermediateDirectories: true
        )
        for category in PromptPresetCategory.allCases {
            try fileManager.createDirectory(
                at: imageGenerationDirectory.appendingPathComponent(category.folderName, isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        let bookmarkData = try imageGenerationDirectory.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(bookmarkData, forKey: sharedFolderBookmarkKey)
    }

    private static func sharedImageGenerationDirectory(fileManager: FileManager) -> URL? {
        if let bookmarkData = UserDefaults.standard.data(forKey: sharedFolderBookmarkKey) {
            var isStale = false
            if let resolvedURL = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                _ = resolvedURL.startAccessingSecurityScopedResource()
                if isStale,
                   let refreshedData = try? resolvedURL.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                   ) {
                    UserDefaults.standard.set(refreshedData, forKey: sharedFolderBookmarkKey)
                }
                return resolvedURL
            }
        }

        guard let candidate = defaultSharedImageGenerationDirectory(fileManager: fileManager) else {
            return nil
        }

        return candidate
    }

    private static func defaultSharedImageGenerationDirectory(fileManager: FileManager) -> URL? {
        let home = fileManager.homeDirectoryForCurrentUser
        let candidate = home
            .appendingPathComponent("Library/CloudStorage/Dropbox-Soundbrenner/Marketing/LLM context Soundbrenner", isDirectory: true)
            .appendingPathComponent("marketing/image generation", isDirectory: true)

        guard fileManager.fileExists(atPath: candidate.deletingLastPathComponent().path) else {
            return nil
        }

        return candidate
    }

    private static func normalizedImageGenerationDirectory(from selectedURL: URL, fileManager: FileManager) -> URL {
        let folderName = selectedURL.lastPathComponent.lowercased()

        if folderName == "models" || folderName == "cameras" || folderName == "styles" {
            return selectedURL.deletingLastPathComponent()
        }

        if folderName == "image generation" {
            return selectedURL
        }

        let marketingImageGenerationURL = selectedURL
            .appendingPathComponent("marketing", isDirectory: true)
            .appendingPathComponent("image generation", isDirectory: true)
        if fileManager.fileExists(atPath: marketingImageGenerationURL.deletingLastPathComponent().path) {
            return marketingImageGenerationURL
        }

        let directImageGenerationURL = selectedURL.appendingPathComponent("image generation", isDirectory: true)
        if fileManager.fileExists(atPath: directImageGenerationURL.deletingLastPathComponent().path) {
            return directImageGenerationURL
        }

        return marketingImageGenerationURL
    }
}

enum ProfileStorageFingerprint {
    static func identifier(
        for directories: [URL],
        fileManager: FileManager = .default
    ) -> String {
        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .contentModificationDateKey,
            .fileSizeKey
        ]

        return directories
            .map(\.standardizedFileURL)
            .sorted { $0.path < $1.path }
            .map { directory in
                var entries = ["root:\(directory.path)"]
                guard let enumerator = fileManager.enumerator(
                    at: directory,
                    includingPropertiesForKeys: Array(resourceKeys),
                    options: [.skipsHiddenFiles]
                ) else {
                    entries.append("missing")
                    return entries.joined(separator: "\n")
                }

                for case let fileURL as URL in enumerator
                where fileURL.pathExtension.caseInsensitiveCompare("json") == .orderedSame {
                    guard let values = try? fileURL.resourceValues(forKeys: resourceKeys),
                          values.isRegularFile == true else {
                        continue
                    }

                    let relativePath = fileURL.path.replacingOccurrences(
                        of: directory.path + "/",
                        with: ""
                    )
                    let modificationTime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
                    entries.append("\(relativePath)|\(values.fileSize ?? 0)|\(modificationTime)")
                }

                return entries.sorted().joined(separator: "\n")
            }
            .joined(separator: "\n---\n")
    }
}

enum StartupProfileCache {
    private static let schemaVersion = 1

    private struct Envelope<Value: Codable>: Codable {
        let schemaVersion: Int
        let storageIdentifier: String
        let value: Value
    }

    static func load<Value: Codable>(
        _ type: Value.Type = Value.self,
        name: String,
        storageIdentifier: String,
        cacheDirectory: URL? = nil
    ) -> Value? {
        let url = cacheURL(name: name, cacheDirectory: cacheDirectory)
        guard let data = try? Data(contentsOf: url),
              let envelope = try? JSONDecoder().decode(Envelope<Value>.self, from: data),
              envelope.schemaVersion == schemaVersion,
              envelope.storageIdentifier == storageIdentifier else {
            return nil
        }
        return envelope.value
    }

    static func save<Value: Codable>(
        _ value: Value,
        name: String,
        storageIdentifier: String,
        cacheDirectory: URL? = nil
    ) {
        let directory = cacheDirectory ?? defaultCacheDirectory()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let envelope = Envelope(
                schemaVersion: schemaVersion,
                storageIdentifier: storageIdentifier,
                value: value
            )
            let data = try JSONEncoder().encode(envelope)
            try data.write(to: cacheURL(name: name, cacheDirectory: directory), options: .atomic)
        } catch {
            // A cache failure must never prevent profiles from loading from their source folders.
        }
    }

    private static func cacheURL(name: String, cacheDirectory: URL?) -> URL {
        (cacheDirectory ?? defaultCacheDirectory()).appendingPathComponent("\(name).json")
    }

    private static func defaultCacheDirectory() -> URL {
        let base = try! FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base
            .appendingPathComponent("SoundbrennerMediaGenerator", isDirectory: true)
            .appendingPathComponent("ProfileCache", isDirectory: true)
    }
}

@MainActor
final class PromptModelStore: ObservableObject {
    @Published private(set) var profiles: [PromptModelProfile] = []

    private let fileManager = FileManager.default
    private var baseDirectoryURL: URL
    private let thumbnailCache = NSCache<NSString, NSImage>()

    init() {
        let baseURL = Self.modelsBaseDirectory()
        self.baseDirectoryURL = baseURL

        if let cachedProfiles: [PromptModelProfile] = StartupProfileCache.load(
            name: "models",
            storageIdentifier: baseURL.standardizedFileURL.path
        ) {
            profiles = cachedProfiles
            return
        }

        do {
            try Self.migrateLegacyProfilesIfNeeded(to: baseURL, fileManager: fileManager)
            try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
            profiles = try loadProfiles()
            persistStartupCache()
        } catch {
            profiles = []
        }
    }

    func reloadStorageLocation() {
        let baseURL = Self.modelsBaseDirectory()
        baseDirectoryURL = baseURL
        thumbnailCache.removeAllObjects()

        do {
            try Self.migrateLegacyProfilesIfNeeded(to: baseURL, fileManager: fileManager)
            try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
            profiles = try loadProfiles()
            persistStartupCache()
        } catch {
            profiles = []
        }
    }

    func upsert(id: UUID?, name: String, thumbnailSourceURL: URL, promptJSON: String) throws {
        try Self.validateJSON(promptJSON, label: name)

        let profileID = id ?? UUID()
        let ext = thumbnailSourceURL.pathExtension.isEmpty ? "png" : thumbnailSourceURL.pathExtension
        let thumbnailFileName = "thumbnail.\(ext)"
        let importedThumbnailData = try Data(contentsOf: thumbnailSourceURL)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousProfile = profiles.first(where: { $0.id == profileID })
        let previousFolderName = previousProfile?.storageFolderName
        let desiredFolderName = Self.sanitizedFolderName(from: trimmedName, fallback: "Untitled Model")
        let folderName = Self.uniqueDirectoryName(
            desiredFolderName,
            in: baseDirectoryURL,
            excluding: previousFolderName,
            fileManager: fileManager
        )
        let folderURL = baseDirectoryURL.appendingPathComponent(folderName, isDirectory: true)

        if let previousFolderName,
           previousFolderName != folderName {
            let previousFolderURL = baseDirectoryURL.appendingPathComponent(previousFolderName, isDirectory: true)
            if fileManager.fileExists(atPath: previousFolderURL.path),
               !fileManager.fileExists(atPath: folderURL.path) {
                try fileManager.moveItem(at: previousFolderURL, to: folderURL)
            }
        }

        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try Self.removeThumbnailFiles(in: folderURL, fileManager: fileManager)
        let destinationURL = folderURL.appendingPathComponent(thumbnailFileName)
        try importedThumbnailData.write(to: destinationURL, options: .atomic)
        try promptJSON.trimmingCharacters(in: .whitespacesAndNewlines)
            .write(to: folderURL.appendingPathComponent("model.json"), atomically: true, encoding: .utf8)
        thumbnailCache.removeAllObjects()

        let profile = PromptModelProfile(
            id: profileID,
            name: trimmedName,
            storageFolderName: folderName,
            thumbnailFileName: thumbnailFileName,
            promptJSON: promptJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }

        profiles.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        persistStartupCache()
    }

    func delete(_ profile: PromptModelProfile) throws {
        profiles.removeAll { $0.id == profile.id }
        let folderURL = baseDirectoryURL.appendingPathComponent(profile.storageFolderName, isDirectory: true)
        if fileManager.fileExists(atPath: folderURL.path) {
            try fileManager.removeItem(at: folderURL)
        }
        thumbnailCache.removeAllObjects()
        persistStartupCache()
    }

    func profile(with id: UUID) -> PromptModelProfile? {
        profiles.first(where: { $0.id == id })
    }

    func thumbnailURL(for profile: PromptModelProfile) -> URL {
        baseDirectoryURL
            .appendingPathComponent(profile.storageFolderName, isDirectory: true)
            .appendingPathComponent(profile.thumbnailFileName)
    }

    func thumbnailURL(for snapshot: GenerationModelSnapshot) -> URL {
        if snapshot.thumbnailFileName.contains("/") {
            return baseDirectoryURL.appendingPathComponent(snapshot.thumbnailFileName)
        }

        return baseDirectoryURL
            .appendingPathComponent("Thumbnails", isDirectory: true)
            .appendingPathComponent(snapshot.thumbnailFileName)
    }

    func snapshotThumbnailFileName(for profile: PromptModelProfile) -> String {
        "\(profile.storageFolderName)/\(profile.thumbnailFileName)"
    }

    func thumbnailImage(for snapshot: GenerationModelSnapshot) -> NSImage? {
        cachedThumbnailImage(named: snapshot.thumbnailFileName, url: thumbnailURL(for: snapshot))
    }

    func thumbnailImage(for profile: PromptModelProfile) -> NSImage? {
        cachedThumbnailImage(named: profile.thumbnailFileName, url: thumbnailURL(for: profile))
    }

    private func cachedThumbnailImage(named fileName: String, url: URL) -> NSImage? {
        let cacheKey = url.path as NSString
        if let cachedImage = thumbnailCache.object(forKey: cacheKey) {
            return cachedImage
        }

        guard let image = NSImage(contentsOf: url) else {
            return nil
        }

        thumbnailCache.setObject(image, forKey: cacheKey)
        return image
    }

    private func loadProfiles() throws -> [PromptModelProfile] {
        let folderProfiles = try Self.loadFolderProfiles(from: baseDirectoryURL, fileManager: fileManager)
        if !folderProfiles.isEmpty {
            return folderProfiles
        }

        let metadataURL = baseDirectoryURL.appendingPathComponent("profiles.json")
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            return []
        }

        let data = try Data(contentsOf: metadataURL)
        return try JSONDecoder().decode([PromptModelProfile].self, from: data)
    }

    private func persistStartupCache() {
        StartupProfileCache.save(
            profiles,
            name: "models",
            storageIdentifier: baseDirectoryURL.standardizedFileURL.path
        )
    }

    static func validateJSON(_ value: String, label: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AppError.invalidModelJSON(label)
        }
        guard let data = trimmed.data(using: .utf8) else {
            throw AppError.invalidModelJSON(label)
        }
        _ = try JSONSerialization.jsonObject(with: data)
    }

    private static func modelsBaseDirectory() -> URL {
        let fileManager = FileManager.default
        let directory = SharedProfileStorage.modelsDirectory(fileManager: fileManager)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func migrateLegacyProfilesIfNeeded(to directory: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if try hasFolderProfiles(in: directory, jsonFileName: "model.json", fileManager: fileManager) {
            return
        }

        let metadataURL = directory.appendingPathComponent("profiles.json")

        let legacyDirectory = SharedProfileStorage.legacyModelsDirectory(fileManager: fileManager)
        let legacyMetadataURL = legacyDirectory.appendingPathComponent("profiles.json")

        if legacyDirectory != directory,
           fileManager.fileExists(atPath: legacyMetadataURL.path),
           !fileManager.fileExists(atPath: metadataURL.path) {
            try fileManager.copyItem(at: legacyMetadataURL, to: metadataURL)
        }

        let legacyThumbnailsURL = legacyDirectory.appendingPathComponent("Thumbnails", isDirectory: true)
        let thumbnailsURL = directory.appendingPathComponent("Thumbnails", isDirectory: true)
        if legacyDirectory != directory,
           fileManager.fileExists(atPath: legacyThumbnailsURL.path),
           !fileManager.fileExists(atPath: thumbnailsURL.path) {
            try fileManager.copyItem(at: legacyThumbnailsURL, to: thumbnailsURL)
        }

        try migrateProfilesJSONToFolders(
            metadataURL: metadataURL,
            thumbnailsURL: thumbnailsURL,
            directory: directory,
            fileManager: fileManager
        )
    }

    private static func migrateProfilesJSONToFolders(
        metadataURL: URL,
        thumbnailsURL: URL,
        directory: URL,
        fileManager: FileManager
    ) throws {
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            return
        }

        let data = try Data(contentsOf: metadataURL)
        let legacyProfiles = try JSONDecoder().decode([PromptModelProfile].self, from: data)
        for legacyProfile in legacyProfiles {
            let desiredFolderName = sanitizedFolderName(from: legacyProfile.name, fallback: "Untitled Model")
            if fileManager.fileExists(
                atPath: directory
                    .appendingPathComponent(desiredFolderName, isDirectory: true)
                    .appendingPathComponent("model.json")
                    .path
            ) {
                continue
            }
            let folderName = uniqueDirectoryName(
                desiredFolderName,
                in: directory,
                excluding: desiredFolderName,
                fileManager: fileManager
            )
            let folderURL = directory.appendingPathComponent(folderName, isDirectory: true)
            let jsonURL = folderURL.appendingPathComponent("model.json")
            let thumbnailURL = folderURL.appendingPathComponent(legacyProfile.thumbnailFileName)

            guard !fileManager.fileExists(atPath: jsonURL.path) else {
                continue
            }

            try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
            try legacyProfile.promptJSON
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .write(to: jsonURL, atomically: true, encoding: .utf8)

            let legacyThumbnailURL = thumbnailsURL.appendingPathComponent(legacyProfile.thumbnailFileName)
            if fileManager.fileExists(atPath: legacyThumbnailURL.path),
               !fileManager.fileExists(atPath: thumbnailURL.path) {
                try fileManager.copyItem(at: legacyThumbnailURL, to: thumbnailURL)
            }
        }
    }

    static func hasFolderProfiles(in directory: URL, jsonFileName: String, fileManager: FileManager) throws -> Bool {
        guard fileManager.fileExists(atPath: directory.path) else {
            return false
        }

        let folderURLs = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        return folderURLs.contains { folderURL in
            guard (try? folderURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return false
            }

            guard !folderURL.lastPathComponent.hasPrefix("_"),
                  folderURL.lastPathComponent != "Thumbnails" else {
                return false
            }

            if fileManager.fileExists(atPath: folderURL.appendingPathComponent(jsonFileName).path) {
                return true
            }

            return (try? hasFolderProfiles(in: folderURL, jsonFileName: jsonFileName, fileManager: fileManager)) ?? false
        }
    }

    private static func loadFolderProfiles(from directory: URL, fileManager: FileManager) throws -> [PromptModelProfile] {
        guard fileManager.fileExists(atPath: directory.path) else {
            return []
        }

        return try loadFolderProfiles(from: directory, baseDirectory: directory, fileManager: fileManager)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func loadFolderProfiles(
        from directory: URL,
        baseDirectory: URL,
        fileManager: FileManager
    ) throws -> [PromptModelProfile] {
        let folderURLs = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        return try folderURLs.flatMap { folderURL -> [PromptModelProfile] in
            guard (try? folderURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  folderURL.lastPathComponent != "Thumbnails",
                  !folderURL.lastPathComponent.hasPrefix("_") else {
                return []
            }

            let jsonURL = folderURL.appendingPathComponent("model.json")
            guard fileManager.fileExists(atPath: jsonURL.path) else {
                return try loadFolderProfiles(from: folderURL, baseDirectory: baseDirectory, fileManager: fileManager)
            }

            let promptJSON = try String(contentsOf: jsonURL, encoding: .utf8)
            guard let thumbnailFileName = try thumbnailFileName(in: folderURL, fileManager: fileManager) else {
                return []
            }

            let relativeFolderName = relativePath(from: baseDirectory, to: folderURL)
            let folderName = folderURL.lastPathComponent
            return [PromptModelProfile(
                id: deterministicUUID(for: "model:\(relativeFolderName)"),
                name: folderName,
                storageFolderName: relativeFolderName,
                thumbnailFileName: thumbnailFileName,
                promptJSON: promptJSON.trimmingCharacters(in: .whitespacesAndNewlines)
            )]
        }
    }

    static func relativePath(from baseURL: URL, to childURL: URL) -> String {
        let basePath = baseURL.standardizedFileURL.path
        let childPath = childURL.standardizedFileURL.path
        guard childPath.hasPrefix(basePath) else {
            return childURL.lastPathComponent
        }

        return String(childPath.dropFirst(basePath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func thumbnailFileName(in folderURL: URL, fileManager: FileManager) throws -> String? {
        let files = try fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        let imageExtensions = Set(["png", "jpg", "jpeg", "heic", "webp", "tiff"])
        return files
            .filter { imageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted {
                if $0.deletingPathExtension().lastPathComponent == "thumbnail" {
                    return true
                }
                if $1.deletingPathExtension().lastPathComponent == "thumbnail" {
                    return false
                }
                return $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
            }
            .first?
            .lastPathComponent
    }

    private static func removeThumbnailFiles(in folderURL: URL, fileManager: FileManager) throws {
        let files = try fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        let imageExtensions = Set(["png", "jpg", "jpeg", "heic", "webp", "tiff"])
        for fileURL in files where imageExtensions.contains(fileURL.pathExtension.lowercased()) {
            try fileManager.removeItem(at: fileURL)
        }
    }

    static func sanitizedFolderName(from name: String, fallback: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let invalidCharacters = CharacterSet(charactersIn: "/:\\")
            .union(.newlines)
            .union(.controlCharacters)
        let components = trimmed.components(separatedBy: invalidCharacters)
        let sanitized = components
            .joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
        return sanitized.isEmpty ? fallback : sanitized
    }

    static func uniqueDirectoryName(
        _ desiredName: String,
        in directory: URL,
        excluding existingName: String?,
        fileManager: FileManager
    ) -> String {
        var candidate = desiredName
        var index = 2

        while fileManager.fileExists(atPath: directory.appendingPathComponent(candidate, isDirectory: true).path),
              candidate != existingName {
            candidate = "\(desiredName) \(index)"
            index += 1
        }

        return candidate
    }

    static func deterministicUUID(for value: String) -> UUID {
        let digest = SHA256.hash(data: Data(value.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let uuid = uuid_t(
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: uuid)
    }
}

@MainActor
final class CameraProfileStore: ObservableObject {
    @Published private(set) var profiles: [CameraProfile] = []

    private let fileManager = FileManager.default
    private var baseDirectoryURL: URL

    init() {
        let baseURL = Self.baseDirectory()
        self.baseDirectoryURL = baseURL

        if let cachedProfiles: [CameraProfile] = StartupProfileCache.load(
            name: "camera-profiles",
            storageIdentifier: baseURL.standardizedFileURL.path
        ) {
            profiles = cachedProfiles
            return
        }

        do {
            try Self.migrateLegacyProfilesIfNeeded(to: baseURL, fileManager: fileManager)
            try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
            profiles = try loadProfiles()
            persistStartupCache()
        } catch {
            profiles = []
        }
    }

    func reloadStorageLocation() {
        let baseURL = Self.baseDirectory()
        baseDirectoryURL = baseURL

        do {
            try Self.migrateLegacyProfilesIfNeeded(to: baseURL, fileManager: fileManager)
            try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
            profiles = try loadProfiles()
            persistStartupCache()
        } catch {
            profiles = []
        }
    }

    func upsert(id: UUID?, name: String, promptJSON: String) throws {
        try PromptModelStore.validateJSON(promptJSON, label: name)

        let profileID = id ?? UUID()
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousProfile = profiles.first(where: { $0.id == profileID })
        let desiredFolderName = PromptModelStore.sanitizedFolderName(from: trimmedName, fallback: "Untitled Style")
        let audienceFolderName = previousProfile?.inferredAudience?.folderName ?? "All"
        let folderName = PromptModelStore.uniqueDirectoryName(
            desiredFolderName,
            in: baseDirectoryURL,
            excluding: previousProfile.map { $0.storageFolderName.split(separator: "/").map(String.init).first ?? $0.storageFolderName },
            fileManager: fileManager
        )
        let folderURL = baseDirectoryURL
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(audienceFolderName, isDirectory: true)

        if let previousFolderName = previousProfile?.storageFolderName,
           previousFolderName != "\(folderName)/\(audienceFolderName)" {
            let previousFolderURL = baseDirectoryURL.appendingPathComponent(previousFolderName, isDirectory: true)
            if fileManager.fileExists(atPath: previousFolderURL.path),
               !fileManager.fileExists(atPath: folderURL.path) {
                try fileManager.moveItem(at: previousFolderURL, to: folderURL)
            }
        }

        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try promptJSON.trimmingCharacters(in: .whitespacesAndNewlines)
            .write(to: folderURL.appendingPathComponent("style.json"), atomically: true, encoding: .utf8)

        let profile = CameraProfile(
            id: profileID,
            name: trimmedName,
            storageFolderName: "\(folderName)/\(audienceFolderName)",
            promptJSON: promptJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }

        profiles.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        persistStartupCache()
    }

    func delete(_ profile: CameraProfile) throws {
        profiles.removeAll { $0.id == profile.id }
        let folderURL = baseDirectoryURL.appendingPathComponent(profile.storageFolderName, isDirectory: true)
        if fileManager.fileExists(atPath: folderURL.path) {
            try fileManager.removeItem(at: folderURL)
        }
        persistStartupCache()
    }

    func profile(with id: UUID) -> CameraProfile? {
        profiles.first(where: { $0.id == id })
    }

    private func loadProfiles() throws -> [CameraProfile] {
        let folderProfiles = try Self.loadFolderProfiles(from: baseDirectoryURL, fileManager: fileManager)
        if !folderProfiles.isEmpty {
            return folderProfiles
        }

        let metadataURL = baseDirectoryURL.appendingPathComponent("profiles.json")
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            return []
        }

        let data = try Data(contentsOf: metadataURL)
        return try JSONDecoder().decode([CameraProfile].self, from: data)
    }

    private func persistStartupCache() {
        StartupProfileCache.save(
            profiles,
            name: "camera-profiles",
            storageIdentifier: baseDirectoryURL.standardizedFileURL.path
        )
    }

    private static func baseDirectory() -> URL {
        let fileManager = FileManager.default
        let directory = SharedProfileStorage.camerasDirectory(fileManager: fileManager)
        migrateSharedCamerasDirectoryToStylesIfNeeded(stylesDirectory: directory, fileManager: fileManager)
        migrateStylesHierarchyIfNeeded(stylesDirectory: directory, fileManager: fileManager)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func migrateSharedCamerasDirectoryToStylesIfNeeded(stylesDirectory: URL, fileManager: FileManager) {
        guard stylesDirectory.lastPathComponent == "styles" else {
            return
        }

        let camerasDirectory = stylesDirectory.deletingLastPathComponent().appendingPathComponent("cameras", isDirectory: true)
        guard fileManager.fileExists(atPath: camerasDirectory.path),
              !fileManager.fileExists(atPath: stylesDirectory.path) else {
            return
        }

        try? fileManager.moveItem(at: camerasDirectory, to: stylesDirectory)
    }

    private static func migrateLegacyProfilesIfNeeded(to directory: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if try PromptModelStore.hasFolderProfiles(in: directory, jsonFileName: "style.json", fileManager: fileManager)
            || (try PromptModelStore.hasFolderProfiles(in: directory, jsonFileName: "camera.json", fileManager: fileManager)) {
            return
        }

        let metadataURL = directory.appendingPathComponent("profiles.json")

        let legacyDirectory = SharedProfileStorage.legacyCamerasDirectory(fileManager: fileManager)
        let legacyMetadataURL = legacyDirectory.appendingPathComponent("profiles.json")

        if legacyDirectory != directory,
           fileManager.fileExists(atPath: legacyMetadataURL.path),
           !fileManager.fileExists(atPath: metadataURL.path) {
            try fileManager.copyItem(at: legacyMetadataURL, to: metadataURL)
        }

        try migrateProfilesJSONToFolders(metadataURL: metadataURL, directory: directory, fileManager: fileManager)
    }

    private static func migrateStylesHierarchyIfNeeded(stylesDirectory: URL, fileManager: FileManager) {
        guard stylesDirectory.lastPathComponent == "styles",
              fileManager.fileExists(atPath: stylesDirectory.path) else {
            return
        }

        let topLevelFolders = (try? fileManager.contentsOfDirectory(
            at: stylesDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var migrationMap: [String: String] = [:]

        for folderURL in topLevelFolders {
            guard (try? folderURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }

            guard !folderURL.lastPathComponent.hasPrefix("_") else {
                continue
            }

            if let audience = AudienceKind.allCases.first(where: { $0.folderName.caseInsensitiveCompare(folderURL.lastPathComponent) == .orderedSame }) {
                migrateAudienceBucketFolder(at: folderURL, audience: audience, stylesDirectory: stylesDirectory, fileManager: fileManager, migrationMap: &migrationMap)
                continue
            }

            if hasDirectStyleJSON(in: folderURL, fileManager: fileManager) {
                migrateDirectStyleFolder(at: folderURL, stylesDirectory: stylesDirectory, fileManager: fileManager, migrationMap: &migrationMap)
            }
        }

        guard !migrationMap.isEmpty else {
            return
        }

        var existingMap = (UserDefaults.standard.dictionary(forKey: PreferenceKeys.cameraProfileIDMigrationKey) as? [String: String]) ?? [:]
        existingMap.merge(migrationMap) { _, new in new }
        UserDefaults.standard.set(existingMap, forKey: PreferenceKeys.cameraProfileIDMigrationKey)
    }

    private static func hasDirectStyleJSON(in folderURL: URL, fileManager: FileManager) -> Bool {
        let styleJSONURL = folderURL.appendingPathComponent("style.json")
        let legacyCameraJSONURL = folderURL.appendingPathComponent("camera.json")
        return fileManager.fileExists(atPath: styleJSONURL.path) || fileManager.fileExists(atPath: legacyCameraJSONURL.path)
    }

    private static func migrateDirectStyleFolder(
        at folderURL: URL,
        stylesDirectory: URL,
        fileManager: FileManager,
        migrationMap: inout [String: String]
    ) {
        let originalRelativePath = PromptModelStore.relativePath(from: stylesDirectory, to: folderURL)
        let destinationURL = folderURL.appendingPathComponent("All", isDirectory: true)
        let destinationRelativePath = PromptModelStore.relativePath(from: stylesDirectory, to: destinationURL)

        let oldID = PromptModelStore.deterministicUUID(for: "style:\(originalRelativePath)")
        let newID = PromptModelStore.deterministicUUID(for: "style:\(destinationRelativePath)")
        migrationMap[oldID.uuidString] = newID.uuidString

        do {
            try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
            let existingContents = try fileManager.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )

            for fileURL in existingContents where (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                let destinationFileURL = destinationURL.appendingPathComponent(fileURL.lastPathComponent)
                if fileManager.fileExists(atPath: destinationFileURL.path) {
                    try? fileManager.removeItem(at: fileURL)
                    continue
                }
                try fileManager.moveItem(at: fileURL, to: destinationFileURL)
            }
        } catch {
            return
        }
    }

    private static func migrateAudienceBucketFolder(
        at folderURL: URL,
        audience: AudienceKind,
        stylesDirectory: URL,
        fileManager: FileManager,
        migrationMap: inout [String: String]
    ) {
        let childFolders = (try? fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for childFolderURL in childFolders {
            guard (try? childFolderURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }

            guard hasDirectStyleJSON(in: childFolderURL, fileManager: fileManager) else {
                continue
            }

            let originalRelativePath = PromptModelStore.relativePath(from: stylesDirectory, to: childFolderURL)
            let destinationURL = stylesDirectory
                .appendingPathComponent(childFolderURL.lastPathComponent, isDirectory: true)
                .appendingPathComponent(audience.folderName, isDirectory: true)
            let destinationRelativePath = PromptModelStore.relativePath(from: stylesDirectory, to: destinationURL)

            let oldID = PromptModelStore.deterministicUUID(for: "style:\(originalRelativePath)")
            let newID = PromptModelStore.deterministicUUID(for: "style:\(destinationRelativePath)")
            migrationMap[oldID.uuidString] = newID.uuidString

            guard !fileManager.fileExists(atPath: destinationURL.path) else {
                try? fileManager.removeItem(at: childFolderURL)
                continue
            }

            do {
                try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.moveItem(at: childFolderURL, to: destinationURL)
            } catch {
                continue
            }
        }

        if let remainingContents = try? fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ), remainingContents.isEmpty {
            try? fileManager.removeItem(at: folderURL)
        }
    }

    private static func migrateProfilesJSONToFolders(metadataURL: URL, directory: URL, fileManager: FileManager) throws {
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            return
        }

        let data = try Data(contentsOf: metadataURL)
        let legacyProfiles = try JSONDecoder().decode([CameraProfile].self, from: data)
        for legacyProfile in legacyProfiles {
            let desiredFolderName = PromptModelStore.sanitizedFolderName(from: legacyProfile.name, fallback: "Untitled Style")
            if fileManager.fileExists(
                atPath: directory
                    .appendingPathComponent(desiredFolderName, isDirectory: true)
                    .appendingPathComponent("style.json")
                    .path
            ) {
                continue
            }
            let folderName = PromptModelStore.uniqueDirectoryName(
                desiredFolderName,
                in: directory,
                excluding: desiredFolderName,
                fileManager: fileManager
            )
            let folderURL = directory
                .appendingPathComponent(folderName, isDirectory: true)
                .appendingPathComponent("All", isDirectory: true)
            let jsonURL = folderURL.appendingPathComponent("style.json")

            guard !fileManager.fileExists(atPath: jsonURL.path) else {
                continue
            }

            try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
            try legacyProfile.promptJSON
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .write(to: jsonURL, atomically: true, encoding: .utf8)
        }
    }

    private static func loadFolderProfiles(from directory: URL, fileManager: FileManager) throws -> [CameraProfile] {
        guard fileManager.fileExists(atPath: directory.path) else {
            return []
        }

        return try loadFolderProfiles(from: directory, baseDirectory: directory, fileManager: fileManager)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func loadFolderProfiles(
        from directory: URL,
        baseDirectory: URL,
        fileManager: FileManager
    ) throws -> [CameraProfile] {
        let folderURLs = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        return try folderURLs.flatMap { folderURL -> [CameraProfile] in
            guard (try? folderURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return []
            }

            guard !folderURL.lastPathComponent.hasPrefix("_") else {
                return []
            }

            let styleJSONURL = folderURL.appendingPathComponent("style.json")
            let legacyCameraJSONURL = folderURL.appendingPathComponent("camera.json")
            let jsonURL = fileManager.fileExists(atPath: styleJSONURL.path) ? styleJSONURL : legacyCameraJSONURL
            guard fileManager.fileExists(atPath: jsonURL.path) else {
                return try loadFolderProfiles(from: folderURL, baseDirectory: baseDirectory, fileManager: fileManager)
            }

            let promptJSON = try String(contentsOf: jsonURL, encoding: .utf8)
            let relativeFolderName = PromptModelStore.relativePath(from: baseDirectory, to: folderURL)
            let displayName = cameraDisplayName(for: folderURL, relativeFolderName: relativeFolderName)
            return [CameraProfile(
                id: PromptModelStore.deterministicUUID(for: "style:\(relativeFolderName)"),
                name: displayName,
                storageFolderName: relativeFolderName,
                promptJSON: promptJSON.trimmingCharacters(in: .whitespacesAndNewlines)
            )]
        }
    }

    private static func loadLegacyDirectFolderProfiles(from directory: URL, fileManager: FileManager) throws -> [CameraProfile] {
        guard fileManager.fileExists(atPath: directory.path) else {
            return []
        }

        let folderURLs = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        return try folderURLs.compactMap { folderURL -> CameraProfile? in
            guard (try? folderURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return nil
            }

            let styleJSONURL = folderURL.appendingPathComponent("style.json")
            let legacyCameraJSONURL = folderURL.appendingPathComponent("camera.json")
            let jsonURL = fileManager.fileExists(atPath: styleJSONURL.path) ? styleJSONURL : legacyCameraJSONURL
            guard fileManager.fileExists(atPath: jsonURL.path) else {
                return nil
            }

            let promptJSON = try String(contentsOf: jsonURL, encoding: .utf8)
            let folderName = cameraDisplayName(for: folderURL, relativeFolderName: folderURL.lastPathComponent)
            return CameraProfile(
                id: PromptModelStore.deterministicUUID(for: "style:\(folderName)"),
                name: folderName,
                storageFolderName: folderName,
                promptJSON: promptJSON.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    private static func cameraDisplayName(for folderURL: URL, relativeFolderName: String) -> String {
        let folderComponents = relativeFolderName
            .split(separator: "/")
            .map { String($0) }

        if let firstComponent = folderComponents.first,
           AudienceKind.allCases.contains(where: { $0.folderName.caseInsensitiveCompare(firstComponent) == .orderedSame }) {
            return folderComponents.dropFirst().last ?? folderURL.lastPathComponent
        }

        if folderComponents.last?.caseInsensitiveCompare("All") == .orderedSame,
           let firstComponent = folderComponents.first {
            return firstComponent
        }

        if let firstComponent = folderComponents.first, folderComponents.count >= 2 {
            return firstComponent
        }

        return folderURL.lastPathComponent
    }
}

@MainActor
final class PromptPresetStore: ObservableObject {
    @Published private(set) var profiles: [PromptPresetProfile] = []

    private let fileManager = FileManager.default

    init() {
        let storageIdentifier = Self.storageIdentifier(fileManager: fileManager)
        if let cachedProfiles: [PromptPresetProfile] = StartupProfileCache.load(
            name: "prompt-presets",
            storageIdentifier: storageIdentifier
        ) {
            profiles = cachedProfiles
            return
        }
        reload()
    }

    func reload() {
        do {
            try seedDefaultsIfNeeded()
            profiles = try PromptPresetCategory.allCases.flatMap(loadProfiles)
                .sorted {
                    if $0.category != $1.category {
                        return $0.category.rawValue < $1.category.rawValue
                    }
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
            persistStartupCache()
        } catch {
            profiles = []
        }
    }

    func profile(with id: String?) -> PromptPresetProfile? {
        guard let id else {
            return nil
        }
        return profiles.first { $0.id == id }
    }

    func profiles(for category: PromptPresetCategory, shotMode: ShotMode) -> [PromptPresetProfile] {
        profiles.filter { profile in
            profile.category == category && (profile.shotMode == nil || profile.shotMode == shotMode)
        }
    }

    func profiles(for category: PromptPresetCategory, shotMode: ShotMode, audience: AudienceKind) -> [PromptPresetProfile] {
        profiles(for: category, shotMode: shotMode, audience: shotMode.usesAudienceSelection ? audience : nil)
    }

    func profiles(for category: PromptPresetCategory, shotMode: ShotMode, audience: AudienceKind?) -> [PromptPresetProfile] {
        profiles(for: category, shotMode: shotMode).filter { profile in
            guard let audience else {
                return profile.inferredAudience == nil
            }

            guard let inferredAudience = profile.inferredAudience else {
                return true
            }
            return inferredAudience == audience
        }
    }

    private func persistStartupCache() {
        StartupProfileCache.save(
            profiles,
            name: "prompt-presets",
            storageIdentifier: Self.storageIdentifier(fileManager: fileManager)
        )
    }

    private static func storageIdentifier(fileManager: FileManager) -> String {
        ProfileStorageFingerprint.identifier(
            for: PromptPresetCategory.allCases.map {
                SharedProfileStorage.promptPresetDirectory(for: $0, fileManager: fileManager)
            },
            fileManager: fileManager
        )
    }

    private func loadProfiles(for category: PromptPresetCategory) throws -> [PromptPresetProfile] {
        let baseURL = SharedProfileStorage.promptPresetDirectory(for: category, fileManager: fileManager)
        try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)

        switch category {
        case .composition:
            return uniquePresetProfiles(try loadFolderProfiles(in: baseURL, category: category, shotMode: nil))
        case .setting:
            var settingProfiles = try loadFolderProfiles(in: baseURL, category: category, shotMode: nil)
            settingProfiles.append(contentsOf: try loadLegacySettingProfiles())
            return uniquePresetProfiles(settingProfiles)
        case .scene, .location:
            return []
        case .look:
            return uniquePresetProfiles(try loadFolderProfiles(in: baseURL, category: category, shotMode: nil))
        }
    }

    private func loadLegacySettingProfiles() throws -> [PromptPresetProfile] {
        let scenesURL = SharedProfileStorage.promptPresetDirectory(for: .scene, fileManager: fileManager)
        let sceneProfiles = try ShotMode.allCases.flatMap { shotMode in
            let shotURL = scenesURL.appendingPathComponent(shotMode.presetFolderName, isDirectory: true)
            return try loadFolderProfiles(in: shotURL, category: .setting, shotMode: shotMode)
        }

        let settingsURL = SharedProfileStorage.promptPresetDirectory(named: "settings", fileManager: fileManager)
        let settingsProfiles = try loadFolderProfiles(in: settingsURL, category: .setting, shotMode: nil)

        return sceneProfiles + settingsProfiles
    }

    private func uniquePresetProfiles(_ profiles: [PromptPresetProfile]) -> [PromptPresetProfile] {
        var seen = Set<String>()
        return profiles.filter { profile in
            let key = "\(profile.shotMode?.rawValue ?? "all")#\(profile.name.lowercased())"
            guard !seen.contains(key) else {
                return false
            }
            seen.insert(key)
            return true
        }
    }

    private func loadFolderProfiles(
        in directoryURL: URL,
        category: PromptPresetCategory,
        shotMode: ShotMode?
    ) throws -> [PromptPresetProfile] {
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            return []
        }

        let folders = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        return try folders.flatMap { folderURL -> [PromptPresetProfile] in
            guard (try? folderURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return []
            }

            guard !folderURL.lastPathComponent.hasPrefix("_") else {
                return []
            }

            let jsonFileNames = [category.jsonFileName] + category.legacyJSONFileNames
            if let jsonURL = jsonFileNames
                .map({ folderURL.appendingPathComponent($0) })
                .first(where: { fileManager.fileExists(atPath: $0.path) }) {
                let promptJSON = try String(contentsOf: jsonURL, encoding: .utf8)
                return [PromptPresetProfile(
                    id: folderURL.standardizedFileURL.path,
                    name: folderURL.lastPathComponent,
                    category: category,
                    shotMode: shotModeForPreset(at: folderURL, fallback: shotMode),
                    directoryURL: folderURL,
                    promptJSON: promptJSON
                )]
            }

            return try loadFolderProfiles(in: folderURL, category: category, shotMode: shotModeForPreset(at: folderURL, fallback: shotMode))
        }
    }

    private func shotModeForPreset(at folderURL: URL, fallback: ShotMode?) -> ShotMode? {
        let pathComponents = folderURL.pathComponents.map { $0.lowercased() }
        return ShotMode.allCases.first { shotMode in
            pathComponents.contains(shotMode.presetFolderName.lowercased())
        } ?? fallback
    }

    private func audienceForPreset(at folderURL: URL) -> AudienceKind? {
        let pathComponents = folderURL.pathComponents.map { $0.lowercased() }
        return AudienceKind.allCases.first { audience in
            pathComponents.contains(audience.folderName.lowercased())
        }
    }

    private func seedDefaultsIfNeeded() throws {
        try seedCompositionPresets()
        try seedScenePresets()
        try seedLocationPresets()
        try seedLookPresets()
    }

    private func seedCompositionPresets() throws {
        try seed(.composition, shotMode: .withModel, name: "Facial closeup direct", json: """
        {
          "composition": "tight facial closeup with product clearly visible on or near the ear",
          "framing": "head and upper neck, face dominant in frame",
          "direction": "subject may look directly at camera, ear with product must remain readable",
          "negative_attributes": ["covered ear", "tiny product", "cropped-out product"]
        }
        """)
        try seed(.composition, shotMode: .withModel, name: "Upper body editorial", json: """
        {
          "composition": "upper body portrait from chest or waist up",
          "framing": "natural editorial crop with enough context for clothing and posture",
          "direction": "product remains visible and not hidden by hair or hands"
        }
        """)
        try seed(.composition, shotMode: .withModel, name: "Full body lifestyle", json: """
        {
          "composition": "full body or near full body lifestyle frame",
          "framing": "show the person in their environment while preserving product readability",
          "direction": "avoid making the product too small; keep a clear visible product side"
        }
        """)
        try seed(.composition, shotMode: .withModel, name: "Side profile ear detail", json: """
        {
          "composition": "side profile portrait focused on the ear and product",
          "framing": "head and shoulders, product side turned toward camera",
          "direction": "hair must be moved away from the ear; product should be large and readable"
        }
        """)
        try seed(.composition, shotMode: .withModel, name: "Over shoulder candid", json: """
        {
          "composition": "over-the-shoulder candid lifestyle crop",
          "framing": "subject partially turned away but product remains visible",
          "direction": "natural posture, not a staged catalogue pose"
        }
        """)
        try seed(.composition, shotMode: .inContext, name: "Wide desk context", json: """
        {
          "composition": "wide contextual product scene",
          "framing": "product is visible within a real-life setup, surrounded by relevant objects",
          "direction": "no human model; hands may appear only if useful and natural"
        }
        """)
        try seed(.composition, shotMode: .inContext, name: "Three-quarter product hero", json: """
        {
          "composition": "three-quarter product hero angle in context",
          "framing": "product is the clear hero, with enough background to show use case",
          "direction": "avoid clutter covering the product silhouette or logo"
        }
        """)
        try seed(.composition, shotMode: .inContext, name: "Flat lay context", json: """
        {
          "composition": "top-down or slight-angle flat lay",
          "framing": "product arranged naturally with related accessories",
          "direction": "no model face; keep product orientation readable"
        }
        """)
        try seed(.composition, shotMode: .inContext, name: "Macro product detail", json: """
        {
          "composition": "macro close-up product detail",
          "framing": "product fills much of the frame with shallow natural depth",
          "direction": "show material, finish, controls, logo, and silhouette clearly"
        }
        """)
        try seed(.composition, shotMode: .productOnWhite, name: "Hero product on white", json: """
        {
          "composition": "clean ecommerce hero product shot",
          "background": "pure white seamless background",
          "lighting": "soft even studio lighting",
          "direction": "product only, no model, no props, no shadows that dirty the white background"
        }
        """)
        try seed(.composition, shotMode: .productOnWhite, name: "Angled product on white", json: """
        {
          "composition": "clean angled product shot on pure white",
          "background": "pure white seamless background",
          "direction": "show shape and depth with a three-quarter angle; no model, no props"
        }
        """)
        try seed(.composition, shotMode: .productOnWhite, name: "Macro product on white", json: """
        {
          "composition": "macro product detail on pure white",
          "background": "pure white seamless background",
          "direction": "focus on finish, logo, button details, and material texture; no model, no props"
        }
        """)
        try seed(.composition, shotMode: .productOnWhite, name: "Tattooed female hands red nails", json: """
        {
          "composition": "premium hand-held product shot on pure white",
          "background": "pure white seamless background",
          "hands": "female hands and partial forearms with generic tattoos and glossy deep red nail polish, holding the product naturally",
          "framing": "hands enter from the lower frame and lift the product toward camera; product remains the clear hero",
          "direction": "show only hands and forearms, no face or body; tattoos should feel real but not depict a specific recognizable design"
        }
        """)
        try seed(.composition, shotMode: .productOnWhite, name: "Tattooed female hands side grip", json: """
        {
          "composition": "side-grip hand-held product shot on pure white",
          "background": "pure white seamless background",
          "hands": "female tattooed hands with glossy deep red nail polish gripping the product from both sides",
          "framing": "tight crop around the product and hands, angled slightly upward for depth",
          "direction": "keep the product silhouette, logo, controls, and finish readable; tattoos are generic texture, not a named or specific tattoo"
        }
        """)
        try seed(.composition, shotMode: .productOnWhite, name: "Tattooed male hands carry", json: """
        {
          "composition": "clean product carry shot on pure white",
          "background": "pure white seamless background",
          "hands": "male tattooed hands and partial forearms holding the product securely, natural nails with no nail polish",
          "framing": "product centered horizontally with hands supporting it from below and behind",
          "direction": "show only hands and forearms, no face or body; tattoos should be generic and unspecific"
        }
        """)
        try seed(.composition, shotMode: .productOnWhite, name: "Tattooed male hand top grip", json: """
        {
          "composition": "single-hand product grip on pure white",
          "background": "pure white seamless background",
          "hands": "one male tattooed hand holding the product from the top or side, natural nails with no nail polish",
          "framing": "close crop with the product front facing camera and the wrist entering from one edge",
          "direction": "minimal studio shadow only; keep tattoos generic without specifying any tattoo subject"
        }
        """)
        try seed(.composition, shotMode: .productOnWhite, name: "Tattooed hands palm support", json: """
        {
          "composition": "product resting across tattooed hands on pure white",
          "background": "pure white seamless background",
          "hands": "tattooed hands supporting the product in open palms, gender-neutral presentation",
          "framing": "slightly top-down angle so the product surface and hand placement are both clear",
          "direction": "hands should feel human and natural, not mannequin-like; tattoos remain generic and secondary to the product"
        }
        """)
        try seed(.composition, shotMode: .productOnWhite, name: "Tattooed hands macro hold", json: """
        {
          "composition": "macro hand-held product detail on pure white",
          "background": "pure white seamless background",
          "hands": "tattooed fingers holding the product near a key material, control, logo, or connector detail",
          "framing": "tight macro crop with shallow depth of field; product detail is sharp and hands frame it naturally",
          "direction": "do not make the tattoo the subject; avoid specific tattoo motifs, letters, symbols, or readable text"
        }
        """)
    }

    private func seedScenePresets() throws {
        try seed(.setting, shotMode: .withModel, name: "Playing drums", json: """
        {
          "scene": "musician actively playing drums",
          "props": ["drum kit", "sticks", "rehearsal or stage details"],
          "direction": "product should stay visible despite movement"
        }
        """)
        try seed(.setting, shotMode: .withModel, name: "Playing guitar", json: """
        {
          "scene": "musician playing guitar in a natural practice or performance moment",
          "props": ["guitar", "cable or amp details"],
          "direction": "avoid overly staged stock-photo posing"
        }
        """)
        try seed(.setting, shotMode: .withModel, name: "At PC battlestation", json: """
        {
          "scene": "gamer at a PC battlestation",
          "props": ["monitor", "keyboard", "mouse", "desk lighting"],
          "direction": "make it feel like a real gaming setup, not a fake showroom"
        }
        """)
        try seed(.setting, shotMode: .withModel, name: "PlayStation couch gaming", json: """
        {
          "scene": "gamer playing console on a couch",
          "props": ["controller", "TV glow", "living room details"],
          "direction": "relaxed real-life gaming moment, not an esports stage"
        }
        """)
        try seed(.setting, shotMode: .withModel, name: "Listening between takes", json: """
        {
          "scene": "musician listening between takes",
          "props": ["instrument nearby", "cables", "small studio details"],
          "direction": "quiet candid moment; product remains visible and believable"
        }
        """)
        try seed(.setting, shotMode: .withModel, name: "Worship keyboard rehearsal", json: """
        {
          "scene": "worship musician at a keyboard during rehearsal",
          "props": ["stage piano", "microphone stand", "music stand", "worship band cables", "soft stage lights"],
          "direction": "authentic church rehearsal moment; product is visible, hair and hands do not cover it"
        }
        """)
        try seed(.setting, shotMode: .withModel, name: "Worship vocalist soundcheck", json: """
        {
          "scene": "worship vocalist during soundcheck",
          "props": ["vocal microphone", "stage monitor", "lyric screen glow", "church stage equipment"],
          "direction": "quiet pre-service soundcheck, not a concert performance; product remains visible and believable"
        }
        """)
        try seed(.setting, shotMode: .withModel, name: "Church drummer behind shield", json: """
        {
          "scene": "worship drummer or music director near a drum kit behind an acrylic shield",
          "props": ["drum kit", "cymbals", "clear drum shield", "in-ear monitor cable", "stage rug"],
          "direction": "real local church stage, practical and warm; avoid arena-concert drama"
        }
        """)
        try seed(.setting, shotMode: .withModel, name: "Motorcycle garage pre-ride", json: """
        {
          "scene": "motorcyclist preparing gear before a ride in a garage",
          "props": ["motorcycle helmet", "gloves", "jacket", "parked motorcycle", "phone mount or keys"],
          "direction": "pre-ride setup only; show the product as low-profile under-helmet audio, not unsafe riding use"
        }
        """)
        try seed(.setting, shotMode: .withModel, name: "Roadside helmet setup", json: """
        {
          "scene": "motorcyclist stopped at a roadside pull-off adjusting helmet or earpiece",
          "props": ["full-face helmet", "gloves", "motorcycle nearby", "roadside viewpoint"],
          "direction": "bike is parked; product is visible during setup, helmet fit and cable routing feel practical"
        }
        """)
        try seed(.setting, shotMode: .withModel, name: "Urban motorcycle commute", json: """
        {
          "scene": "urban motorcyclist preparing for a commute",
          "props": ["helmet", "riding jacket", "parking garage or city street", "backpack or sling"],
          "direction": "modern practical commute, not racing; avoid unsafe active-riding headphone depiction"
        }
        """)
        try seed(.setting, shotMode: .inContext, name: "Gaming desk accessories", json: """
        {
          "scene": "product placed among gaming accessories",
          "props": ["keyboard", "controller", "mouse", "headphones", "desk mat"],
          "people": "no model, no face"
        }
        """)
        try seed(.setting, shotMode: .inContext, name: "Packed travel kit", json: """
        {
          "scene": "product inside or beside a compact travel kit",
          "props": ["case", "cable", "notebook", "bag details"],
          "people": "no model, no face",
          "direction": "practical everyday carry context, tidy but not sterile"
        }
        """)
        try seed(.setting, shotMode: .inContext, name: "On instrument case", json: """
        {
          "scene": "product resting on or beside an instrument case",
          "props": ["case texture", "stick bag or cable", "small music accessories"],
          "people": "no model, no face"
        }
        """)
        try seed(.setting, shotMode: .inContext, name: "Musician desk context", json: """
        {
          "scene": "product in a musician workspace",
          "props": ["audio interface", "cables", "notebook", "instrument details"],
          "people": "no model, no face"
        }
        """)
        try seed(.setting, shotMode: .inContext, name: "Backstage flight case closeup", json: """
        {
          "scene": "product placed on a black road-worn flight case or amp case backstage",
          "props": ["coiled audio cable", "gaffer tape", "guitar picks", "setlist paper with no readable text", "small metal hardware"],
          "people": "no model, no face",
          "direction": "moody practical backstage light with product sharply readable; premium music-gear context, not a cluttered junk pile"
        }
        """)
        try seed(.setting, shotMode: .inContext, name: "Analog listening desk", json: """
        {
          "scene": "product on a compact analog listening desk or shelf",
          "props": ["vinyl record sleeve with no readable text", "small speaker or headphone stand", "warm desk lamp", "coiled cable", "wood or black textured surface"],
          "people": "no model, no face",
          "direction": "clean editorial product-in-context scene with warm hi-fi mood; product remains the hero and should not be hidden among props"
        }
        """)
        try seed(.setting, shotMode: .inContext, name: "Tattooed hands product hold", json: """
        {
          "scene": "close product-in-context shot where tattooed hands hold the product like premium music gear",
          "props": ["minimal black or white studio surface", "subtle cable or case edge only if useful"],
          "people": "hands and partial forearms only, no face or full model",
          "hands": "tattooed hands holding, lifting, or presenting the product; optional deep red nail polish for female-presenting hands, natural nails for male-presenting hands",
          "direction": "product remains sharply readable and central; tattoos are generic atmosphere and must not depict a specific motif, readable words, or recognizable symbols"
        }
        """)
        try seed(.setting, shotMode: .inContext, name: "Church stage gear", json: """
        {
          "scene": "product placed among worship stage gear",
          "props": ["stage piano corner", "vocal microphone", "music stand", "cable coils", "worship team setlist"],
          "people": "no model, no face",
          "direction": "warm church rehearsal context, tidy but real, no readable lyrics or branded church names"
        }
        """)
        try seed(.setting, shotMode: .inContext, name: "Motorcycle gear flat lay", json: """
        {
          "scene": "product arranged with motorcycle riding gear before a ride",
          "props": ["helmet", "gloves", "jacket sleeve", "keys", "phone mount", "garage workbench"],
          "people": "no model, no face",
          "direction": "premium practical gear-prep context; no active riding scene"
        }
        """)
    }

    private func seedLocationPresets() throws {
        try seed(.setting, shotMode: nil, name: "Home studio", json: """
        {
          "location": "home studio",
          "environment": "personal, lived-in creative workspace",
          "lighting": "natural window light with practical lamps"
        }
        """)
        try seed(.setting, shotMode: nil, name: "Rehearsal room", json: """
        {
          "location": "band rehearsal room",
          "environment": "slightly messy, authentic musician space",
          "lighting": "available light, practical and believable"
        }
        """)
        try seed(.setting, shotMode: nil, name: "Bedroom desk", json: """
        {
          "location": "bedroom desk setup",
          "environment": "casual, personal, realistic everyday setup",
          "lighting": "soft mixed ambient light"
        }
        """)
        try seed(.setting, shotMode: nil, name: "Urban outdoor", json: """
        {
          "location": "urban outdoor setting",
          "environment": "street, waterfront, or city background with natural depth",
          "lighting": "soft daylight, realistic exposure"
        }
        """)
        try seed(.setting, shotMode: nil, name: "Small venue backstage", json: """
        {
          "location": "small venue backstage",
          "environment": "dim practical lights, gear cases, realistic performance prep",
          "lighting": "mixed available light, moody but still product-readable"
        }
        """)
        try seed(.setting, shotMode: nil, name: "Modern apartment", json: """
        {
          "location": "modern apartment",
          "environment": "clean but lived-in lifestyle setting",
          "lighting": "soft natural window light"
        }
        """)
        try seed(.setting, shotMode: nil, name: "Minimal studio", json: """
        {
          "location": "minimal photo studio",
          "environment": "controlled simple backdrop, little visual noise",
          "lighting": "large softbox or window-like studio light"
        }
        """)
        try seed(.setting, shotMode: nil, name: "Modern church stage", json: """
        {
          "location": "modern church worship stage",
          "environment": "warm contemporary sanctuary with stage piano, vocal microphones, drum shield, cables, lyric screens, and soft amber or purple stage light",
          "lighting": "available church stage lighting, warm and realistic, not a concert arena or nightclub",
          "negative_attributes": ["cathedral architecture", "mega-church spectacle", "nightclub lighting", "excessive haze", "fake instruments", "readable copyrighted lyrics"]
        }
        """)
        try seed(.setting, shotMode: nil, name: "Motorcycle garage", json: """
        {
          "location": "motorcycle garage or covered parking area",
          "environment": "parked motorcycle, helmet shelf, gloves, jacket, tools or gear bench, practical pre-ride atmosphere",
          "lighting": "available garage light or open-door daylight, realistic and slightly imperfect",
          "negative_attributes": ["unsafe active riding", "racing fantasy", "biker gang cliche", "oversized headphones"]
        }
        """)
        try seed(.setting, shotMode: nil, name: "Roadside ride stop", json: """
        {
          "location": "roadside pull-off or scenic ride stop",
          "environment": "parked motorcycle, helmet in hand, road or viewpoint in background, calm practical travel mood",
          "lighting": "natural daylight or golden-hour available light",
          "negative_attributes": ["riding at speed", "dangerous traffic", "extreme motocross mud", "stunt photography"]
        }
        """)
    }

    private func seedLookPresets() throws {
        try seed(.look, shotMode: nil, name: "iPhone realism", json: """
        {
          "capture_style": "realistic iPhone photo",
          "camera": "26mm to 35mm equivalent lens feel",
          "texture": "natural digital noise, slight imperfect focus, believable dynamic range",
          "negative_attributes": ["studio campaign gloss", "CGI feel", "overprocessed skin"]
        }
        """)
        try seed(.look, shotMode: nil, name: "Editorial photoshoot", json: """
        {
          "capture_style": "editorial photoshoot",
          "lighting": "intentional but not overly commercial",
          "color": "premium realistic tones with controlled contrast"
        }
        """)
        try seed(.look, shotMode: nil, name: "Muted film", json: """
        {
          "capture_style": "muted film photography",
          "texture": "subtle grain, gentle highlight rolloff, organic color",
          "negative_attributes": ["heavy vintage filter", "fake light leaks"]
        }
        """)
        try seed(.look, shotMode: nil, name: "Clean studio", json: """
        {
          "capture_style": "clean modern studio photography",
          "lighting": "soft controlled studio light with gentle shadows",
          "color": "accurate product color, crisp but not CGI"
        }
        """)
        try seed(.look, shotMode: nil, name: "Flash candid", json: """
        {
          "capture_style": "direct flash candid photo",
          "lighting": "on-camera flash with realistic falloff",
          "texture": "slightly raw nightlife or backstage feel",
          "negative_attributes": ["polished campaign lighting", "perfect studio gradients"]
        }
        """)
        try seed(.look, shotMode: nil, name: "Premium product render", json: """
        {
          "capture_style": "premium realistic product render",
          "lighting": "controlled reflections, clean shadow shaping",
          "direction": "product must look physically plausible, not cartoonish or overly glossy"
        }
        """)
    }

    private func seed(
        _ category: PromptPresetCategory,
        shotMode: ShotMode?,
        name: String,
        json: String
    ) throws {
        let baseURL = SharedProfileStorage.promptPresetDirectory(for: category, fileManager: fileManager)
        var parentURL = baseURL

        if let audience = audienceForSeed(category: category, name: name, json: json) {
            parentURL = parentURL.appendingPathComponent(audience.folderName, isDirectory: true)
        } else if category == .setting {
            parentURL = parentURL.appendingPathComponent("All", isDirectory: true)
        }

        if let shotMode, category == .composition || category == .setting {
            parentURL = parentURL.appendingPathComponent(shotMode.presetFolderName, isDirectory: true)
        }

        let folderName = PromptModelStore.sanitizedFolderName(from: name, fallback: category.title)
        let folderURL = parentURL.appendingPathComponent(folderName, isDirectory: true)
        let jsonURL = folderURL.appendingPathComponent(category.jsonFileName)
        guard !fileManager.fileExists(atPath: jsonURL.path) else {
            return
        }

        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try json.trimmingCharacters(in: .whitespacesAndNewlines).write(to: jsonURL, atomically: true, encoding: .utf8)
    }

    private func audienceForSeed(category: PromptPresetCategory, name: String, json: String) -> AudienceKind? {
        guard category == .setting else {
            return nil
        }

        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let explicitNames: [String: AudienceKind] = [
            "playing drums": .musicians,
            "playing guitar": .musicians,
            "listening between takes": .musicians,
            "musician desk context": .musicians,
            "on instrument case": .musicians,
            "packed travel kit": .musicians,
            "home studio": .musicians,
            "rehearsal room": .musicians,
            "small venue backstage": .musicians,
            "at pc battlestation": .gamers,
            "playstation couch gaming": .gamers,
            "gaming desk accessories": .gamers,
            "bedroom desk": .gamers,
            "worship keyboard rehearsal": .worshipMusicians,
            "worship vocalist soundcheck": .worshipMusicians,
            "church drummer behind shield": .worshipMusicians,
            "church stage gear": .worshipMusicians,
            "modern church stage": .worshipMusicians,
            "motorcycle garage pre-ride": .motorcyclists,
            "roadside helmet setup": .motorcyclists,
            "urban motorcycle commute": .motorcyclists,
            "motorcycle gear flat lay": .motorcyclists,
            "motorcycle garage": .motorcyclists,
            "roadside ride stop": .motorcyclists,
            "urban outdoor": .motorcyclists,
        ]

        if let audience = explicitNames[normalizedName] {
            return audience
        }

        let searchableText = "\(name)\n\(json)".lowercased()
        let audienceSignals: [(AudienceKind, [String])] = [
            (.motorcyclists, [
                "motorcycle", "motorcyclist", "moto", "rider", "helmet", "garage",
                "roadside", "touring", "commute", "bike", "pre-ride"
            ]),
            (.worshipMusicians, [
                "worship", "church", "sanctuary", "praise team", "service", "sermon",
                "drum shield", "stage piano", "worship leader", "soundcheck"
            ]),
            (.gamers, [
                "gamer", "gaming", "pc", "playstation", "console", "controller",
                "battlestation", "keyboard", "mouse", "esports"
            ]),
            (.musicians, [
                "musician", "music", "drum", "guitar", "piano", "rehearsal",
                "instrument", "song"
            ])
        ]

        return audienceSignals.first { _, signals in
            signals.contains(where: searchableText.contains)
        }?.0
    }
}

/// File extensions recognized as reference images. Used to identify images by
/// name instead of fully decoding every file, which is prohibitively slow at
/// launch when profile folders contain many generated images.
private let referenceImageFileExtensions: Set<String> = [
    "png", "jpg", "jpeg", "heic", "heif", "webp", "tif", "tiff", "gif", "bmp"
]

private func isReferenceImageFile(_ url: URL) -> Bool {
    referenceImageFileExtensions.contains(url.pathExtension.lowercased())
}

@MainActor
final class ProductReferenceStore: ObservableObject {
    @Published private(set) var products: [ProductReferenceProfile] = []

    private let fileManager = FileManager.default

    init() {
        let directory = SharedProfileStorage.productsDirectory(fileManager: fileManager)
        if let cachedProducts: [ProductReferenceProfile] = StartupProfileCache.load(
            name: "products",
            storageIdentifier: directory.standardizedFileURL.path
        ) {
            products = cachedProducts
            return
        }
        reload()
    }

    func reload() {
        let productsDirectory = SharedProfileStorage.productsDirectory(fileManager: fileManager)

        do {
            try fileManager.createDirectory(at: productsDirectory, withIntermediateDirectories: true)
            let folders = try fileManager.contentsOfDirectory(
                at: productsDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            products = folders.flatMap(loadProducts)
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            StartupProfileCache.save(
                products,
                name: "products",
                storageIdentifier: productsDirectory.standardizedFileURL.path
            )
        } catch {
            products = []
        }
    }

    func product(with id: String?) -> ProductReferenceProfile? {
        guard let id else {
            return nil
        }

        return products.first { $0.id == id }
    }

    private func loadProducts(from directoryURL: URL) -> [ProductReferenceProfile] {
        guard isDiscoverableProductDirectory(directoryURL),
              (try? directoryURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            return []
        }

        let contents = directoryContents(in: directoryURL)
        let childProductFolders = contents.filter { url in
            isDiscoverableProductDirectory(url)
                && ((try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true)
        }
        let collectionJSONs = jsonFiles(in: directoryURL)

        if !childProductFolders.isEmpty {
            return childProductFolders.flatMap { productURL in
                loadCollectionProducts(collectionURL: directoryURL, productURL: productURL, collectionJSONs: collectionJSONs)
            }
        }

        return loadLegacyProduct(from: directoryURL).map { [$0] } ?? []
    }

    private func loadCollectionProducts(
        collectionURL: URL,
        productURL: URL,
        collectionJSONs: [URL]
    ) -> [ProductReferenceProfile] {
        let productJSONs = collectionJSONs + jsonFiles(in: productURL)
        let productImages = referenceImages(in: productURL)
        let shotFolders = directoryContents(in: productURL)
            .filter { url in
                isDiscoverableProductDirectory(url)
                    && ((try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true)
            }

        if !shotFolders.isEmpty {
            return shotFolders.flatMap { shotURL in
                loadShotGroupProducts(
                    collectionURL: collectionURL,
                    productURL: productURL,
                    shotURL: shotURL,
                    baseJSONs: productJSONs,
                    baseImageURLs: productImages
                )
            }
        }

        if !productJSONs.isEmpty {
            return productJSONs.compactMap { jsonURL in
                loadCollectionProduct(
                    collectionURL: collectionURL,
                    productURL: productURL,
                    jsonURL: jsonURL
                )
            }
        }

        return loadLegacyProduct(from: productURL).map { [$0] } ?? []
    }

    private func loadShotGroupProducts(
        collectionURL: URL,
        productURL: URL,
        shotURL: URL,
        baseJSONs: [URL],
        baseImageURLs: [URL]
    ) -> [ProductReferenceProfile] {
        let shotJSONs = baseJSONs + jsonFiles(in: shotURL)
        let shotImages = uniqueURLs(baseImageURLs + referenceImages(in: shotURL))
        let variantFolders = directoryContents(in: shotURL)
            .filter { url in
                isDiscoverableProductDirectory(url)
                    && ((try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true)
            }

        if !variantFolders.isEmpty {
            return variantFolders.compactMap { variantURL in
                loadNestedProductVariant(
                    collectionURL: collectionURL,
                    productURL: productURL,
                    shotURL: shotURL,
                    variantURL: variantURL,
                    baseJSONs: shotJSONs,
                    baseImageURLs: shotImages
                )
            }
        }

        let promptJSON = combinedPromptJSON(from: shotJSONs)
        let referenceImageURLs = shotImages

        guard promptJSON != nil || !referenceImageURLs.isEmpty else {
            return []
        }

        let productName = productURL.lastPathComponent
        let shotName = shotURL.lastPathComponent
        let shotMode = shotModeForProductGroup(shotName)
        return [
            ProductReferenceProfile(
                id: "\(shotURL.standardizedFileURL.path)#\(shotJSONs.map(\.lastPathComponent).joined(separator: ","))",
                name: "\(productName) - \(shotName)",
                collectionName: collectionURL.lastPathComponent,
                productName: productName,
                variantName: shotName,
                shotMode: shotMode,
                directoryURL: shotURL,
                promptJSON: promptJSON,
                referenceImageURLs: referenceImageURLs
            )
        ]
    }

    private func loadNestedProductVariant(
        collectionURL: URL,
        productURL: URL,
        shotURL: URL,
        variantURL: URL,
        baseJSONs: [URL],
        baseImageURLs: [URL]
    ) -> ProductReferenceProfile? {
        let variantJSONs = jsonFiles(in: variantURL)
            .sorted { preferredJSONRank($0) < preferredJSONRank($1) }
        let promptJSON = combinedPromptJSON(from: baseJSONs + variantJSONs)
        let referenceImageURLs = uniqueURLs(baseImageURLs + referenceImages(in: variantURL))

        guard promptJSON != nil || !referenceImageURLs.isEmpty else {
            return nil
        }

        let productName = productURL.lastPathComponent
        let shotName = shotURL.lastPathComponent
        let variantName = variantURL.lastPathComponent
        let shotMode = shotModeForProductGroup(shotName)

        return ProductReferenceProfile(
            id: "\(variantURL.standardizedFileURL.path)#\(baseJSONs.map(\.lastPathComponent).joined(separator: ","))#\(variantJSONs.map(\.lastPathComponent).joined(separator: ","))",
            name: "\(productName) - \(shotName) - \(variantName)",
            collectionName: collectionURL.lastPathComponent,
            productName: productName,
            variantName: "\(shotName) - \(variantName)",
            shotMode: shotMode,
            directoryURL: variantURL,
            promptJSON: promptJSON,
            referenceImageURLs: referenceImageURLs
        )
    }

    private func loadCollectionProduct(
        collectionURL: URL,
        productURL: URL,
        jsonURL: URL
    ) -> ProductReferenceProfile? {
        let promptJSON = combinedPromptJSON(from: [jsonURL])
        let referenceImageURLs = referenceImages(in: productURL)

        guard promptJSON != nil || !referenceImageURLs.isEmpty else {
            return nil
        }

        let variantName = variantDisplayName(from: jsonURL)
        let productName = productURL.lastPathComponent

        return ProductReferenceProfile(
            id: "\(productURL.standardizedFileURL.path)#\(jsonURL.lastPathComponent)",
            name: "\(productName) - \(variantName)",
            collectionName: collectionURL.lastPathComponent,
            productName: productName,
            variantName: variantName,
            shotMode: nil,
            directoryURL: productURL,
            promptJSON: promptJSON,
            referenceImageURLs: referenceImageURLs
        )
    }

    private func loadCollectionProductLegacy(
        collectionURL: URL,
        productURL: URL,
        collectionJSONs: [URL]
    ) -> [ProductReferenceProfile] {
        return collectionJSONs.compactMap { jsonURL in
            loadCollectionProduct(
                collectionURL: collectionURL,
                productURL: productURL,
                jsonURL: jsonURL
            )
        }
    }

    private func loadCollectionVariantProduct(
        collectionURL: URL,
        productURL: URL,
        variantURL: URL,
        collectionJSONs: [URL]
    ) -> ProductReferenceProfile? {
        let variantJSONs = jsonFiles(in: variantURL)
            .sorted { preferredJSONRank($0) < preferredJSONRank($1) }
        let promptJSON = combinedPromptJSON(from: collectionJSONs + variantJSONs)
        let referenceImageURLs = uniqueURLs(referenceImages(in: productURL) + referenceImages(in: variantURL))

        guard promptJSON != nil || !referenceImageURLs.isEmpty else {
            return nil
        }

        let productName = productURL.lastPathComponent
        let variantName = variantURL.lastPathComponent

        return ProductReferenceProfile(
            id: "\(variantURL.standardizedFileURL.path)#\(collectionJSONs.map(\.lastPathComponent).joined(separator: ","))#\(variantJSONs.map(\.lastPathComponent).joined(separator: ","))",
            name: "\(productName) - \(variantName)",
            collectionName: collectionURL.lastPathComponent,
            productName: productName,
            variantName: variantName,
            shotMode: nil,
            directoryURL: variantURL,
            promptJSON: promptJSON,
            referenceImageURLs: referenceImageURLs
        )
    }

    private func loadLegacyProduct(from directoryURL: URL) -> ProductReferenceProfile? {
        guard (try? directoryURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            return nil
        }

        let jsonURL = jsonFiles(in: directoryURL)
            .sorted { preferredJSONRank($0) < preferredJSONRank($1) }
            .first
        let promptJSON = jsonURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        let referenceImageURLs = referenceImages(in: directoryURL)

        guard promptJSON != nil || !referenceImageURLs.isEmpty else {
            return nil
        }

        return ProductReferenceProfile(
            id: directoryURL.standardizedFileURL.path,
            name: directoryURL.lastPathComponent,
            collectionName: nil,
            productName: directoryURL.lastPathComponent,
            variantName: jsonURL.map(variantDisplayName),
            shotMode: nil,
            directoryURL: directoryURL,
            promptJSON: promptJSON,
            referenceImageURLs: referenceImageURLs
        )
    }

    private func shotModeForProductGroup(_ name: String) -> ShotMode? {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "model", "with model", "on model", "model shot", "model shots":
            return .withModel
        case "in context", "context", "lifestyle", "context shot", "context shots":
            return .inContext
        case "product on white", "white", "on white", "product only", "ecommerce":
            return .productOnWhite
        case "plain":
            return .plain
        default:
            return nil
        }
    }

    private func directoryContents(in directoryURL: URL) -> [URL] {
        (try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentTypeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
    }

    private func isDiscoverableProductDirectory(_ url: URL) -> Bool {
        let folderName = url.lastPathComponent.lowercased()
        let reservedFolderNames = [
            "image generation",
            "models",
            "styles",
            "cameras",
            "thumbnails",
            "compositions",
            "settings",
            "locations",
            "looks",
            "ad angles"
        ]

        return !folderName.hasPrefix("_") && !reservedFolderNames.contains(folderName)
    }

    private func jsonFiles(in directoryURL: URL) -> [URL] {
        directoryContents(in: directoryURL)
            .filter { $0.pathExtension.lowercased() == "json" }
    }

    private func referenceImages(in directoryURL: URL) -> [URL] {
        directoryContents(in: directoryURL)
            .filter(isReferenceImageFile)
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func combinedPromptJSON(from urls: [URL]) -> String? {
        let JSONs = urls.compactMap { url -> (URL, String)? in
            guard let rawJSON = try? String(contentsOf: url, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawJSON.isEmpty else {
                return nil
            }

            return (url, rawJSON)
        }

        guard !JSONs.isEmpty else {
            return nil
        }

        if JSONs.count == 1 {
            return JSONs[0].1
        }

        let entries = JSONs.map { url, rawJSON in
            let key = promptJSONKey(from: url)
            return """
              "\(key)": \(rawJSON)
            """
        }

        return """
        {
        \(entries.joined(separator: ",\n"))
        }
        """
    }

    private func promptJSONKey(from url: URL) -> String {
        let fileName = url.deletingPathExtension().lastPathComponent.lowercased()
        if fileName == "product" || fileName == "reference" {
            return "collection_reference"
        }

        if fileName == "variant" || fileName == "delta" {
            return "variant_reference"
        }

        return fileName
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
    }

    private func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { url in
            let path = url.standardizedFileURL.path
            guard !seen.contains(path) else {
                return false
            }
            seen.insert(path)
            return true
        }
    }

    private func variantDisplayName(from url: URL) -> String {
        url.deletingPathExtension()
            .lastPathComponent
            .replacingOccurrences(of: "model shots - ", with: "", options: [.caseInsensitive])
    }

    private func preferredJSONRank(_ url: URL) -> String {
        let name = url.lastPathComponent.lowercased()
        if name == "reference.json" {
            return "0"
        }
        if name == "product.json" {
            return "1"
        }
        return "2-\(name)"
    }
}

@MainActor
final class AdAngleStore: ObservableObject {
    @Published private(set) var adAngles: [AdAngleProfile] = []

    private let fileManager = FileManager.default

    init() {
        let directory = SharedProfileStorage.adAnglesDirectory(fileManager: fileManager)
        if let cachedAdAngles: [AdAngleProfile] = StartupProfileCache.load(
            name: "ad-angles",
            storageIdentifier: directory.standardizedFileURL.path
        ) {
            adAngles = cachedAdAngles
            return
        }
        reload()
    }

    func reload() {
        let directory = SharedProfileStorage.adAnglesDirectory(fileManager: fileManager)

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let folders = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            adAngles = folders.compactMap(loadAdAngle)
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            StartupProfileCache.save(
                adAngles,
                name: "ad-angles",
                storageIdentifier: directory.standardizedFileURL.path
            )
        } catch {
            adAngles = []
        }
    }

    func adAngle(with id: String?) -> AdAngleProfile? {
        guard let id else {
            return nil
        }

        return adAngles.first { $0.id == id }
    }

    private func loadAdAngle(from folderURL: URL) -> AdAngleProfile? {
        guard (try? folderURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            return nil
        }

        let jsonURL = preferredJSON(in: folderURL)
        let referenceImageURLs = referenceImages(in: folderURL)

        guard let jsonURL,
              let promptJSON = try? String(contentsOf: jsonURL, encoding: .utf8),
              !promptJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return AdAngleProfile(
            id: folderURL.standardizedFileURL.path,
            name: folderURL.lastPathComponent,
            directoryURL: folderURL,
            promptJSON: promptJSON,
            referenceImageURLs: referenceImageURLs
        )
    }

    private func preferredJSON(in directoryURL: URL) -> URL? {
        let contents = directoryContents(in: directoryURL)
            .filter { $0.pathExtension.lowercased() == "json" }

        return contents.first { $0.lastPathComponent == "angle_prompt.json" }
            ?? contents.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }.first
    }

    private func referenceImages(in directoryURL: URL) -> [URL] {
        directoryContents(in: directoryURL)
            .filter(isReferenceImageFile)
            .sorted { lhs, rhs in
                if lhs.lastPathComponent == "thumbnail.png" { return true }
                if rhs.lastPathComponent == "thumbnail.png" { return false }
                return lhs.lastPathComponent.localizedCaseInsensitiveCompare(rhs.lastPathComponent) == .orderedAscending
            }
    }

    private func directoryContents(in directoryURL: URL) -> [URL] {
        (try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentTypeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
    }
}

@MainActor
final class PromotionalContextStore: ObservableObject {
    @Published private(set) var promotionalContexts: [PromotionalContextProfile] = []

    private let fileManager = FileManager.default

    init() {
        let directory = SharedProfileStorage.promotionalContextsDirectory(fileManager: fileManager)
        if let cachedPromotionalContexts: [PromotionalContextProfile] = StartupProfileCache.load(
            name: "promotional-contexts",
            storageIdentifier: directory.standardizedFileURL.path
        ) {
            promotionalContexts = cachedPromotionalContexts
            return
        }
        reload()
    }

    func reload() {
        let directory = SharedProfileStorage.promotionalContextsDirectory(fileManager: fileManager)

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let folders = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            promotionalContexts = folders.compactMap(loadPromotionalContext)
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            StartupProfileCache.save(
                promotionalContexts,
                name: "promotional-contexts",
                storageIdentifier: directory.standardizedFileURL.path
            )
        } catch {
            promotionalContexts = []
        }
    }

    func promotionalContext(with id: String?) -> PromotionalContextProfile? {
        guard let id else {
            return nil
        }

        return promotionalContexts.first { $0.id == id }
    }

    private func loadPromotionalContext(from folderURL: URL) -> PromotionalContextProfile? {
        guard (try? folderURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            return nil
        }

        let jsonURL = preferredJSON(in: folderURL)
        let referenceImageURLs = referenceImages(in: folderURL)

        guard let jsonURL,
              let promptJSON = try? String(contentsOf: jsonURL, encoding: .utf8),
              !promptJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return PromotionalContextProfile(
            id: folderURL.standardizedFileURL.path,
            name: folderURL.lastPathComponent,
            directoryURL: folderURL,
            promptJSON: promptJSON,
            referenceImageURLs: referenceImageURLs
        )
    }

    private func preferredJSON(in directoryURL: URL) -> URL? {
        let contents = directoryContents(in: directoryURL)
            .filter { $0.pathExtension.lowercased() == "json" }

        return contents.first { $0.lastPathComponent == "promo.json" }
            ?? contents.first { $0.lastPathComponent == "promotional_context.json" }
            ?? contents.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }.first
    }

    private func referenceImages(in directoryURL: URL) -> [URL] {
        directoryContents(in: directoryURL)
            .filter(isReferenceImageFile)
            .sorted { lhs, rhs in
                if lhs.lastPathComponent == "thumbnail.png" { return true }
                if rhs.lastPathComponent == "thumbnail.png" { return false }
                return lhs.lastPathComponent.localizedCaseInsensitiveCompare(rhs.lastPathComponent) == .orderedAscending
            }
    }

    private func directoryContents(in directoryURL: URL) -> [URL] {
        (try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentTypeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
    }
}

@MainActor
final class AppModel: ObservableObject {
    private static let maxGenerationAttempts = 3
    private static let adLocalizationConcurrencyLimit = 3
    private static let formPersistenceDebounceNanoseconds: UInt64 = 350_000_000
    static let referenceLikenessSafetyRule = """
    Reference likeness rule:
    Use attached model and reference photos only for broad creative direction such as pose, framing, lighting, styling, wardrobe, mood, and composition. Do not recreate, clone, or closely resemble any real person shown in a reference photo. If a person is needed, generate a new fictional person with different facial features, face shape, skin details, hairline, distinctive marks, and overall identity. Product references may still be matched accurately for product shape, materials, branding, and proportions.
    """
    private static let adLocalizationFolderBookmarkKey = "ad_localization_folder_bookmark"
    private static let selectedAdLocalizationLanguagesKey = "selected_ad_localization_languages"
    private static let selectedAdLocalizationProductKey = "selected_ad_localization_product"
    private static let adLocalizationAudioChronicleURLKey = "ad_localization_audio_chronicle_url"
    @Published var form = GenerationForm() {
        didSet {
            scheduleFormPersistence()
        }
    }
    @Published var generatorMode: GeneratorMode = .regular
    @Published var apiKey = ""
    @Published var geminiAPIKey = ""
    @Published var isGenerating = false
    @Published var pendingGenerations: [PendingGenerationBatch] = []
    @Published var adLocalizationFolderURL: URL?
    @Published var selectedAdLocalizationLanguages: Set<AdLocalizationLanguage> = [.germanEUR] {
        didSet {
            persistAdLocalizationLanguages()
        }
    }
    @Published var selectedAdLocalizationProduct: AdLocalizationProduct = .none {
        didSet {
            persistAdLocalizationProduct()
        }
    }
    @Published var adLocalizationAudioChronicleURL = "" {
        didSet {
            persistAdLocalizationAudioChronicleURL()
        }
    }
    @Published var adLocalizationJobs: [AdLocalizationJob] = []
    @Published var isAdLocalizationRunning = false
    @Published var lastError: String?
    @Published var statusMessage = "Ready"
    @Published var selectedJobID: UUID?
    @Published var referenceImageURLs: [URL] = []
    @Published var selectedModelIDs: [UUID] = [] {
        didSet {
            persistPreferences()
        }
    }
    var selectedModelID: UUID? {
        selectedModelIDs.first
    }
    @Published var randomModelMode: RandomModelMode = .none {
        didSet {
            if randomModelMode != .none {
                selectedModelIDs = []
            }
            persistPreferences()
        }
    }
    var useRandomModel: Bool {
        randomModelMode != .none
    }
    @Published var selectedCameraID: UUID? {
        didSet {
            persistPreferences()
        }
    }
    @Published var selectedProductID: String? {
        didSet {
            persistPreferences()
        }
    }
    @Published var selectedAdAngleIDs: [String] = [] {
        didSet {
            persistPreferences()
        }
    }
    var selectedAdAngleID: String? {
        get { selectedAdAngleIDs.first }
        set { selectedAdAngleIDs = newValue.map { [$0] } ?? [] }
    }
    @Published var useRandomAdAngle = false {
        didSet {
            if useRandomAdAngle {
                selectedAdAngleIDs = []
            }
            persistPreferences()
        }
    }
    @Published var selectedPromotionalContextIDs: [String] = [] {
        didSet {
            persistPreferences()
        }
    }
    var selectedPromotionalContextID: String? {
        get { selectedPromotionalContextIDs.first }
        set { selectedPromotionalContextIDs = newValue.map { [$0] } ?? [] }
    }
    @Published var useRandomPromotionalContext = false {
        didSet {
            if useRandomPromotionalContext {
                selectedPromotionalContextIDs = []
            }
            persistPreferences()
        }
    }
    @Published var selectedPresetIDs: [PromptPresetCategory: [String]] = [:] {
        didSet {
            persistPreferences()
        }
    }
    @Published var randomPresetCategories: Set<PromptPresetCategory> = [] {
        didSet {
            persistPreferences()
        }
    }
    @Published private(set) var setupRevision = 0
    @Published var isModelManagerPresented = false
    @Published var isCameraManagerPresented = false
    @Published var availableImageModels: [ImageModelOption] = OpenAIImageService.defaultImageModels
    @Published var imageModelRefreshStatus = "Using default image model list."

    private let apiKeyStore = APIKeyStore()
    private let geminiAPIKeyStore = SecureAPIKeyStore(
        service: "com.soundbrenner.mediagenerator",
        account: "gemini-api-key"
    )
    private let preferences = AppPreferencesStore()
    private let service = OpenAIImageService()
    private let geminiService = GeminiImageService()
    private let adLocalizationTruthService = AdLocalizationTruthService()
    private let fileManager = FileManager.default
    private let referenceImagesDirectoryURL: URL
    private let adLocalizationJobsURL: URL
    private var isRestoringPreferences = false
    private var pendingFormPersistenceTask: Task<Void, Never>?

    init() {
        referenceImagesDirectoryURL = Self.referenceImagesDirectory()
        adLocalizationJobsURL = Self.appSupportFile(named: "ad-localization-jobs.json")
        isRestoringPreferences = true
        if let savedForm = preferences.loadForm() {
            form = savedForm
        }
        selectedModelIDs = preferences.loadSelectedModelIDs()
        randomModelMode = preferences.loadRandomModelMode()
        selectedCameraID = preferences.loadSelectedCameraID()
        selectedProductID = preferences.loadSelectedProductID()
        selectedAdAngleIDs = preferences.loadSelectedAdAngleIDs()
        useRandomAdAngle = preferences.loadRandomAdAngle()
        selectedPromotionalContextIDs = preferences.loadSelectedPromotionalContextIDs()
        useRandomPromotionalContext = false
        selectedPromotionalContextIDs = Array(selectedPromotionalContextIDs.prefix(1))
        selectedPresetIDs = preferences.loadSelectedPresetIDLists()
        randomPresetCategories = preferences.loadRandomPresetCategories()
        selectedAdLocalizationLanguages = Self.loadAdLocalizationLanguages()
        selectedAdLocalizationProduct = Self.loadAdLocalizationProduct()
        adLocalizationAudioChronicleURL = Self.loadAdLocalizationAudioChronicleURL()
        adLocalizationFolderURL = Self.loadAdLocalizationFolderURL()
        adLocalizationJobs = Self.loadAdLocalizationJobs(from: adLocalizationJobsURL)
        apiKey = apiKeyStore.read()
        geminiAPIKey = geminiAPIKeyStore.read()
        isRestoringPreferences = false
    }

    func saveAPIKey() {
        do {
            try apiKeyStore.write(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
            statusMessage = "API key saved locally."
            lastError = nil
            Task {
                await refreshAvailableImageModels()
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func saveGeminiAPIKey() {
        do {
            let trimmedKey = geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            try geminiAPIKeyStore.write(trimmedKey)
            statusMessage = "Gemini API key saved securely."
            lastError = nil
            guard !trimmedKey.isEmpty else {
                return
            }
            Task {
                do {
                    try await geminiService.validateAPIKey(trimmedKey)
                    statusMessage = "Nano Banana Pro is connected."
                    lastError = nil
                } catch {
                    statusMessage = "Gemini key saved, but validation failed."
                    lastError = error.localizedDescription
                }
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refreshAvailableImageModels() async {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            availableImageModels = OpenAIImageService.defaultImageModels
            imageModelRefreshStatus = "Add an API key to refresh the live model list."
            if !availableImageModels.contains(where: { $0.id == form.imageModel }) {
                form.imageModel = availableImageModels.first?.id ?? ImageModelOption.preferredModel
            }
            return
        }

        do {
            let models = try await service.fetchAvailableImageModels(apiKey: trimmedKey)
            availableImageModels = models
            if !models.contains(where: { $0.id == form.imageModel }) {
                form.imageModel = models.first?.id ?? ImageModelOption.preferredModel
            }
            imageModelRefreshStatus = "Live model list refreshed from the API."
        } catch {
            availableImageModels = OpenAIImageService.defaultImageModels
            if !availableImageModels.contains(where: { $0.id == form.imageModel }) {
                form.imageModel = availableImageModels.first?.id ?? ImageModelOption.preferredModel
            }
            imageModelRefreshStatus = "Live refresh failed. Using fallback list."
        }
    }

    func addReferenceImages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image]

        if panel.runModal() == .OK {
            do {
                let importedURLs = try panel.urls.map(importReferenceImage)
                let additions = importedURLs.filter { !referenceImageURLs.contains($0) }
                referenceImageURLs.append(contentsOf: additions)
                statusMessage = "Imported \(additions.count) reference photo\(additions.count == 1 ? "" : "s")."
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func removeReferenceImage(_ url: URL) {
        referenceImageURLs.removeAll { $0 == url }
    }

    func chooseAdLocalizationFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the folder that contains the static ads to localize."
        panel.prompt = "Use Folder"

        if let desktopURL = try? fileManager.url(
            for: .desktopDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) {
            panel.directoryURL = desktopURL
        }

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return
        }

        do {
            let bookmarkData = try selectedURL.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmarkData, forKey: Self.adLocalizationFolderBookmarkKey)
            adLocalizationFolderURL = selectedURL
            statusMessage = "Ad folder selected: \(selectedURL.lastPathComponent)."
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func toggleAdLocalizationLanguage(_ language: AdLocalizationLanguage) {
        if selectedAdLocalizationLanguages.contains(language) {
            selectedAdLocalizationLanguages.remove(language)
        } else {
            selectedAdLocalizationLanguages.insert(language)
        }
    }

    var adLocalizationFailures: [AdLocalizationFailure] {
        adLocalizationJobs.compactMap { job in
            guard job.status == .failed, let message = job.errorMessage else {
                return nil
            }
            return AdLocalizationFailure(
                id: "\(job.sourcePath)-\(job.language.rawValue)",
                sourceFileName: job.sourceFileName,
                languageTitle: job.language.title,
                message: message
            )
        }
    }

    var adLocalizationProgressText: String {
        guard !adLocalizationJobs.isEmpty else {
            return "No localization batch has run yet."
        }

        let succeeded = adLocalizationJobs.filter { $0.status == .succeeded }.count
        let skipped = adLocalizationJobs.filter { $0.status == .skipped }.count
        let failed = adLocalizationJobs.filter { $0.status == .failed }.count
        let running = adLocalizationJobs.filter { $0.status == .running }.count
        return "\(succeeded)/\(adLocalizationJobs.count) done\(skipped > 0 ? ", \(skipped) skipped" : "")\(running > 0 ? ", \(running) running" : "")\(failed > 0 ? ", \(failed) failed" : "")"
    }

    func startAdLocalization() {
        do {
            let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedAPIKey.isEmpty else {
                throw AppError.missingAPIKey
            }
            guard let folderURL = adLocalizationFolderURL else {
                throw AppError.missingAdLocalizationFolder
            }
            guard !selectedAdLocalizationLanguages.isEmpty else {
                throw AppError.missingAdLocalizationLanguages
            }

            _ = folderURL.startAccessingSecurityScopedResource()
            let sourceURLs = try Self.imageFiles(in: folderURL, fileManager: fileManager)
            guard !sourceURLs.isEmpty else {
                throw AppError.emptyAdLocalizationFolder
            }

            let outputDirectory = folderURL.appendingPathComponent("Localized ads", isDirectory: true)
            try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            let languages = selectedAdLocalizationLanguages.sorted { $0.title < $1.title }
            let jobs = sourceURLs.flatMap { sourceURL in
                languages.map { language in
                    makeAdLocalizationJob(sourceURL: sourceURL, language: language, outputDirectory: outputDirectory)
                }
            }

            adLocalizationJobs = jobs
            persistAdLocalizationJobs()
            isAdLocalizationRunning = true
            statusMessage = selectedAdLocalizationProduct == .none
                ? "Fetching scoped article truth..."
                : "Fetching current \(selectedAdLocalizationProduct.title) prices and scoped article truth..."
            lastError = nil

            Task {
                await runAdLocalizationJobs(apiKey: trimmedAPIKey, outputDirectory: outputDirectory)
            }
        } catch {
            lastError = error.localizedDescription
            statusMessage = "Ad localization failed to start."
        }
    }

    func toggleModelSelection(_ id: UUID) {
        randomModelMode = .none
        if selectedModelIDs.contains(id) {
            selectedModelIDs.removeAll { $0 == id }
        } else {
            selectedModelIDs.append(id)
        }
    }

    func selectModel(_ id: UUID?) {
        randomModelMode = .none
        selectedModelIDs = id.map { [$0] } ?? []
    }

    func selectModels(_ ids: [UUID]) {
        randomModelMode = .none
        selectedModelIDs = ids
    }

    func selectRandomModel(_ isEnabled: Bool) {
        randomModelMode = isEnabled ? .all : .none
        if isEnabled {
            selectedModelIDs = []
        }
    }

    func selectRandomModelMode(_ mode: RandomModelMode) {
        randomModelMode = mode
        if mode != .none {
            selectedModelIDs = []
        }
    }

    func selectCamera(_ id: UUID?) {
        selectedCameraID = id
    }

    func selectProduct(_ id: String?) {
        selectedProductID = id
    }

    func selectAdAngle(_ id: String?) {
        selectedAdAngleIDs = id.map { [$0] } ?? []
    }

    func toggleAdAngleSelection(_ id: String) {
        useRandomAdAngle = false
        if selectedAdAngleIDs.contains(id) {
            selectedAdAngleIDs.removeAll { $0 == id }
        } else {
            selectedAdAngleIDs.append(id)
        }
    }

    func selectRandomAdAngle(_ isEnabled: Bool) {
        useRandomAdAngle = isEnabled
        if isEnabled {
            selectedAdAngleIDs = []
        }
    }

    func selectPromotionalContext(_ id: String?) {
        useRandomPromotionalContext = false
        selectedPromotionalContextIDs = id.map { [$0] } ?? []
    }

    func togglePromotionalContext(_ id: String) {
        useRandomPromotionalContext = false
        if selectedPromotionalContextIDs.contains(id) {
            selectedPromotionalContextIDs.removeAll { $0 == id }
        } else {
            selectedPromotionalContextIDs.append(id)
        }
    }

    func selectPromotionalContexts(_ ids: [String]) {
        useRandomPromotionalContext = false
        selectedPromotionalContextIDs = Array(ids.prefix(1))
    }

    func selectRandomPromotionalContext(_ isEnabled: Bool) {
        useRandomPromotionalContext = isEnabled
        if isEnabled {
            selectedPromotionalContextIDs = []
        }
    }

    func selectPreset(_ id: String?, for category: PromptPresetCategory) {
        randomPresetCategories.remove(category)
        selectedPresetIDs[category] = id.map { [$0] } ?? []
    }

    func togglePresetSelection(_ id: String, for category: PromptPresetCategory) {
        randomPresetCategories.remove(category)
        var ids = selectedPresetIDs[category] ?? []
        if ids.contains(id) {
            ids.removeAll { $0 == id }
        } else {
            ids.append(id)
        }
        selectedPresetIDs[category] = ids
    }

    func toggleRandomPreset(for category: PromptPresetCategory) {
        if randomPresetCategories.contains(category) {
            randomPresetCategories.remove(category)
        } else {
            selectedPresetIDs[category] = []
            randomPresetCategories.insert(category)
        }
    }

    func clearCreativeLayers() {
        randomModelMode = .none
        selectedModelIDs = []
        useRandomAdAngle = false
        selectedAdAngleIDs = []
        useRandomPromotionalContext = false
        selectedPromotionalContextIDs = []
        randomPresetCategories = []
        selectedPresetIDs = [:]
    }

    func persistDraftForm(_ draftForm: GenerationForm) {
        form = draftForm
    }

    func applySetup(prompt: String, modelID: UUID?, cameraID: UUID?, productID: String?, adAngleID: String? = nil, randomAdAngle: Bool = false, promotionalContextID: String? = nil, randomPromotionalContext: Bool = false, shotMode: ShotMode = .withModel, audience: AudienceKind = .musicians, presetIDs: [PromptPresetCategory: String] = [:], randomModelMode: RandomModelMode = .none, randomPresetCategories: Set<PromptPresetCategory> = [], referenceImageURLs: [URL]) {
        applySetup(prompt: prompt, modelIDs: modelID.map { [$0] } ?? [], cameraID: cameraID, productID: productID, adAngleID: adAngleID, randomAdAngle: randomAdAngle, promotionalContextIDs: promotionalContextID.map { [$0] } ?? [], randomPromotionalContext: randomPromotionalContext, shotMode: shotMode, audience: audience, presetIDs: presetIDs, randomModelMode: randomModelMode, randomPresetCategories: randomPresetCategories, referenceImageURLs: referenceImageURLs)
    }

    func applySetup(prompt: String, modelIDs: [UUID], cameraID: UUID?, productID: String?, adAngleID: String? = nil, randomAdAngle: Bool = false, promotionalContextID: String? = nil, randomPromotionalContext: Bool = false, shotMode: ShotMode = .withModel, audience: AudienceKind = .musicians, presetIDs: [PromptPresetCategory: String] = [:], randomModelMode: RandomModelMode = .none, randomPresetCategories: Set<PromptPresetCategory> = [], referenceImageURLs: [URL]) {
        applySetup(prompt: prompt, modelIDs: modelIDs, cameraID: cameraID, productID: productID, adAngleID: adAngleID, randomAdAngle: randomAdAngle, promotionalContextIDs: promotionalContextID.map { [$0] } ?? [], randomPromotionalContext: randomPromotionalContext, shotMode: shotMode, audience: audience, presetIDs: presetIDs, randomModelMode: randomModelMode, randomPresetCategories: randomPresetCategories, referenceImageURLs: referenceImageURLs)
    }

    func applySetup(prompt: String, modelIDs: [UUID], cameraID: UUID?, productID: String?, adAngleID: String? = nil, randomAdAngle: Bool = false, promotionalContextIDs: [String] = [], randomPromotionalContext: Bool = false, shotMode: ShotMode = .withModel, audience: AudienceKind = .musicians, presetIDs: [PromptPresetCategory: String] = [:], randomModelMode: RandomModelMode = .none, randomPresetCategories: Set<PromptPresetCategory> = [], referenceImageURLs: [URL]) {
        form.prompt = prompt
        form.shotMode = shotMode
        form.audience = audience
        self.randomModelMode = shotMode.allowsModelSelection ? randomModelMode : .none
        selectedModelIDs = self.randomModelMode == .none ? modelIDs : []
        selectedCameraID = cameraID
        selectedProductID = productID
        useRandomAdAngle = randomAdAngle
        selectedAdAngleIDs = randomAdAngle ? [] : adAngleID.map { [$0] } ?? []
        useRandomPromotionalContext = false
        selectedPromotionalContextIDs = Array(promotionalContextIDs.prefix(1))
        selectedPresetIDs = presetIDs.mapValues { [$0] }
        self.randomPresetCategories = Set(randomPresetCategories.filter { $0.applies(to: shotMode) })
        self.referenceImageURLs = referenceImageURLs
        setupRevision += 1
    }

    func generate(
        form draftForm: GenerationForm,
        using galleryStore: GalleryStore,
        modelStore: PromptModelStore,
        cameraStore: CameraProfileStore,
        productStore: ProductReferenceStore,
        adAngleStore: AdAngleStore,
        promotionalContextStore: PromotionalContextStore,
        presetStore: PromptPresetStore
    ) {
        do {
            form = draftForm
            let trimmedAPIKey = try generationAPIKey(for: draftForm)
            let isPlainMode = draftForm.shotMode == .plain
            let selectedProduct = isPlainMode ? nil : try resolvedSelectedProduct(from: productStore, form: draftForm)
            let selectedAdAngles = isPlainMode ? [] : try resolvedSelectedAdAngles(from: adAngleStore)
            let selectedAdAngle = selectedAdAngles.first
            let selectedPromotionalContexts = isPlainMode ? [] : try resolvedSelectedPromotionalContexts(from: promotionalContextStore)
            let fixedPresets = isPlainMode ? [] : try resolvedSelectedPresets(from: presetStore, shotMode: draftForm.shotMode, audience: draftForm.audience)
            let inputPrompt = draftForm.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            let userReferenceSnapshots = makeReferenceSnapshots(from: referenceImageURLs)
            let productSnapshot = selectedProduct.map { GenerationProductSnapshot(name: $0.name) }
            let fixedAdAngleSnapshot = selectedAdAngle.map { GenerationAdAngleSnapshot(name: $0.name) }
            let fixedPromotionalContextSnapshots = selectedPromotionalContexts.map { GenerationPromotionalContextSnapshot(name: $0.name) }
            let fixedPromotionalContextSnapshot = fixedPromotionalContextSnapshots.first
            let allowsModels = !isPlainMode && draftForm.shotMode.allowsModelSelection
            let usesRandomModels = allowsModels && randomModelMode != .none
            let usesRandomAdAngle = !isPlainMode && useRandomAdAngle && !adAngleStore.adAngles.isEmpty
            let activeRandomPresetCategories = randomPresetCategories.filter { $0.applies(to: draftForm.shotMode) }
            let storedRandomPresetCategories = activeRandomPresetCategories.sorted { $0.rawValue < $1.rawValue }
            let usesRandomPresets = !activeRandomPresetCategories.isEmpty
            let usesMultipleSelectedModels = allowsModels && randomModelMode == .none && selectedModelIDs.count > 1
            let usesMultipleSelectedAdAngles = !usesRandomAdAngle && selectedAdAngles.count > 1
            let usesMultipleSelectedPresets = Dictionary(grouping: fixedPresets, by: \.category).values.contains { $0.count > 1 }
            let shouldGroupRequests = usesRandomModels || usesMultipleSelectedModels || usesRandomPresets || usesMultipleSelectedPresets || usesRandomAdAngle || usesMultipleSelectedAdAngles
            let modelBatches = allowsModels
                ? try resolvedModelBatches(from: modelStore, imageCount: draftForm.sanitizedImageCount)
                : [[]]

            if shouldGroupRequests {
                var requestForms = [GenerationForm]()
                var modelNames = [String]()
                var modelSnapshots = [GenerationModelSnapshot]()
                var presetSnapshots = Set<GenerationPresetSnapshot>()
                var adAngleSnapshots = Set<GenerationAdAngleSnapshot>()
                var promotionalContextSnapshots = Set<GenerationPromotionalContextSnapshot>()
                var referenceURLsByRequest = [[URL]]()
                var referenceImportCache = [String: URL]()

                for imageIndex in 0..<draftForm.sanitizedImageCount {
                    let selectedModels = modelBatches[min(imageIndex, modelBatches.count - 1)]
                    let requestAdAngle = resolvedAdAngleForRequest(
                        selectedAdAngles: selectedAdAngles,
                        adAngleStore: adAngleStore,
                        imageIndex: imageIndex,
                        useRandom: usesRandomAdAngle
                    )
                    let requestPromotionalContexts = selectedPromotionalContexts
                    let selectedPresets = try resolvedPresetsForRequest(
                        from: presetStore,
                        shotMode: draftForm.shotMode,
                        audience: draftForm.audience,
                        fixedPresets: fixedPresets,
                        imageIndex: imageIndex
                    )
                    presetSnapshots.formUnion(selectedPresets.map {
                        GenerationPresetSnapshot(category: $0.category, name: $0.name)
                    })
                    modelNames.append(contentsOf: selectedModels.map(\.name))
                    modelSnapshots.append(contentsOf: selectedModels.map {
                        GenerationModelSnapshot(name: $0.name, thumbnailFileName: modelStore.snapshotThumbnailFileName(for: $0))
                    })
                    if let requestAdAngle {
                        adAngleSnapshots.insert(GenerationAdAngleSnapshot(name: requestAdAngle.name))
                    }
                    for requestPromotionalContext in requestPromotionalContexts {
                        promotionalContextSnapshots.insert(GenerationPromotionalContextSnapshot(name: requestPromotionalContext.name))
                    }

                    let finalPrompt = buildPrompt(
                        form: draftForm,
                        with: selectedModels,
                        productProfile: selectedProduct,
                        adAngleProfile: requestAdAngle,
                        promotionalContextProfiles: requestPromotionalContexts,
                        presets: selectedPresets
                    )
                    let requestReferenceURLs = try buildReferenceURLs(
                        productProfile: selectedProduct,
                        adAngleProfile: requestAdAngle,
                        promotionalContextProfiles: requestPromotionalContexts,
                        importCache: &referenceImportCache
                    )

                    var requestForm = draftForm
                    requestForm.prompt = finalPrompt
                    requestForm.imageCount = 1
                    requestForms.append(requestForm)
                    referenceURLsByRequest.append(requestReferenceURLs)
                }
                let referenceURLs = uniqueURLs(referenceURLsByRequest.flatMap { $0 })
                let referenceSnapshots = makeReferenceSnapshots(from: referenceURLs)

                queueGroupedGeneration(
                    apiKey: trimmedAPIKey,
                    requestForms: requestForms,
                    referenceURLsByRequest: referenceURLsByRequest,
                    inputPrompt: inputPrompt,
                    referenceURLs: referenceURLs,
                    referenceSnapshots: referenceSnapshots,
                    modelNames: modelNames,
                    modelSnapshots: modelSnapshots,
                    cameraSnapshot: makeSetupSnapshot(presets: presetSnapshots.map(\.name).sorted()),
                    presetSnapshots: presetSnapshots.sorted {
                        if $0.category != $1.category {
                            return $0.category.rawValue < $1.category.rawValue
                        }
                        return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                    },
                    randomModelMode: usesRandomModels ? randomModelMode : .none,
                    randomPresetCategories: storedRandomPresetCategories,
                    productSnapshot: productSnapshot,
                    adAngleSnapshot: usesRandomAdAngle || usesMultipleSelectedAdAngles
                        ? makeSetupSnapshot(adAngles: adAngleSnapshots.map(\.name).sorted())
                        : fixedAdAngleSnapshot,
                    randomAdAngle: usesRandomAdAngle,
                    promotionalContextSnapshot: fixedPromotionalContextSnapshot,
                    promotionalContextSnapshots: fixedPromotionalContextSnapshots,
                    randomPromotionalContext: false,
                    userReferenceImages: userReferenceSnapshots,
                    galleryStore: galleryStore
                )
                syncGenerationState()
                statusMessage = "Queued \(requestForms.count) randomized image\(requestForms.count == 1 ? "" : "s")."
                lastError = nil
                return
            }

            for selectedModels in modelBatches {
                let modelNames = selectedModels.map(\.name)
                let modelSnapshots = selectedModels.map {
                    GenerationModelSnapshot(name: $0.name, thumbnailFileName: modelStore.snapshotThumbnailFileName(for: $0))
                }
                let finalPrompt = buildPrompt(
                    form: draftForm,
                    with: selectedModels,
                    productProfile: selectedProduct,
                    adAngleProfile: selectedAdAngle,
                    promotionalContextProfiles: selectedPromotionalContexts,
                    presets: fixedPresets
                )
                let referenceURLs = try buildReferenceURLs(productProfile: selectedProduct, adAngleProfile: selectedAdAngle, promotionalContextProfiles: selectedPromotionalContexts)
                let referenceSnapshots = makeReferenceSnapshots(from: referenceURLs)

                var requestForm = draftForm
                requestForm.prompt = finalPrompt
                requestForm.imageCount = draftForm.sanitizedImageCount

                queueGeneration(
                    apiKey: trimmedAPIKey,
                    requestForm: requestForm,
                    inputPrompt: inputPrompt,
                    referenceURLs: referenceURLs,
                    referenceSnapshots: referenceSnapshots,
                    modelNames: modelNames,
                    modelSnapshots: modelSnapshots,
                    cameraSnapshot: makeSetupSnapshot(presets: fixedPresets.map(\.name)),
                    presetSnapshots: fixedPresets.map { GenerationPresetSnapshot(category: $0.category, name: $0.name) },
                    randomModelMode: .none,
                    randomPresetCategories: storedRandomPresetCategories,
                    productSnapshot: productSnapshot,
                    adAngleSnapshot: fixedAdAngleSnapshot,
                    randomAdAngle: false,
                    promotionalContextSnapshot: fixedPromotionalContextSnapshot,
                    promotionalContextSnapshots: fixedPromotionalContextSnapshots,
                    randomPromotionalContext: false,
                    userReferenceImages: userReferenceSnapshots,
                    galleryStore: galleryStore
                )
            }

            syncGenerationState()
            let queuedCount = modelBatches.reduce(0) { total, batch in
                total + (usesRandomModels ? 1 : draftForm.sanitizedImageCount)
            }
            statusMessage = usesRandomModels
                ? "Queued \(queuedCount) random-model prompt\(queuedCount == 1 ? "" : "s")."
                : "Queued \(queuedCount) image\(queuedCount == 1 ? "" : "s")."
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            statusMessage = "Generation failed."
        }
    }

    private func queueGroupedGeneration(
        apiKey: String,
        requestForms: [GenerationForm],
        referenceURLsByRequest: [[URL]],
        inputPrompt: String,
        referenceURLs: [URL],
        referenceSnapshots: [GenerationReferenceImageSnapshot],
        modelNames: [String],
        modelSnapshots: [GenerationModelSnapshot],
        cameraSnapshot: GenerationCameraSnapshot?,
        presetSnapshots: [GenerationPresetSnapshot],
        randomModelMode: RandomModelMode,
        randomPresetCategories: [PromptPresetCategory],
        productSnapshot: GenerationProductSnapshot?,
        adAngleSnapshot: GenerationAdAngleSnapshot?,
        randomAdAngle: Bool,
        promotionalContextSnapshot: GenerationPromotionalContextSnapshot?,
        promotionalContextSnapshots: [GenerationPromotionalContextSnapshot] = [],
        randomPromotionalContext: Bool,
        userReferenceImages: [GenerationReferenceImageSnapshot],
        galleryStore: GalleryStore
    ) {
        guard let firstRequestForm = requestForms.first else {
            return
        }

        var pendingForm = firstRequestForm
        pendingForm.imageCount = requestForms.count
        let pendingBatch = PendingGenerationBatch(
            prompt: inputPrompt,
            promptWithJSONs: requestForms.count == 1
                ? requestForms[0].prompt
                : requestForms.enumerated()
                    .map { index, requestForm in
                        "Image \(index + 1):\n\(requestForm.prompt)"
                    }
                    .joined(separator: "\n\n"),
            imageModel: pendingForm.imageModel,
            quality: pendingForm.quality,
            resolution: pendingForm.resolution,
            geminiAspectRatio: pendingForm.geminiAspectRatio,
            geminiImageSize: pendingForm.geminiImageSize,
            imageCount: pendingForm.sanitizedImageCount,
            outputFormat: pendingForm.outputFormat,
            shotMode: pendingForm.shotMode,
            audience: pendingForm.audience,
            randomModelMode: randomModelMode,
            randomPresetCategories: randomPresetCategories,
            modelSnapshots: modelSnapshots,
            cameraSnapshot: cameraSnapshot,
            presetSnapshots: presetSnapshots,
            productSnapshot: productSnapshot,
            adAngleSnapshot: adAngleSnapshot,
            randomAdAngle: randomAdAngle,
            promotionalContextSnapshot: promotionalContextSnapshot,
            promotionalContextSnapshots: promotionalContextSnapshots,
            randomPromotionalContext: randomPromotionalContext,
            referenceImages: referenceSnapshots,
            userReferenceImages: userReferenceImages
        )

        try? galleryStore.addPendingRecord(
            id: pendingBatch.id,
            form: pendingForm,
            inputPrompt: inputPrompt,
            referenceImageCount: referenceURLs.count,
            randomModelMode: randomModelMode,
            randomPresetCategories: randomPresetCategories,
            modelNames: modelNames,
            modelSnapshots: modelSnapshots,
            cameraSnapshot: cameraSnapshot,
            presetSnapshots: presetSnapshots,
            productSnapshot: productSnapshot,
            adAngleSnapshot: adAngleSnapshot,
            randomAdAngle: randomAdAngle,
            promotionalContextSnapshot: promotionalContextSnapshot,
            promotionalContextSnapshots: promotionalContextSnapshots,
            randomPromotionalContext: randomPromotionalContext,
            referenceImages: referenceSnapshots,
            userReferenceImages: userReferenceImages
        )
        pendingGenerations.insert(pendingBatch, at: 0)

        Task {
            var payloads = [GeneratedImagePayload]()
            var finalForms = [GenerationForm]()
            var usedQualityFallback = false

            do {
                for (requestOffset, requestForm) in requestForms.enumerated() {
                    let requestIndex = finalForms.count + 1
                    updatePendingGeneration(
                        id: pendingBatch.id,
                        status: "Request \(requestIndex)/\(requestForms.count)",
                        detail: "Sending randomized prompt \(requestIndex) of \(requestForms.count) to \(requestForm.imageModel.isGeminiImageModel ? "Nano Banana Pro" : "OpenAI")."
                    )
                    let result = try await generateWithRetry(
                        apiKey: apiKey,
                        form: requestForm,
                        referenceImageURLs: referenceURLsByRequest.indices.contains(requestOffset)
                            ? referenceURLsByRequest[requestOffset]
                            : referenceURLs,
                        pendingID: pendingBatch.id,
                        requestIndex: requestIndex,
                        requestTotal: requestForms.count
                    )
                    payloads.append(contentsOf: result.payloads)
                    finalForms.append(result.form)
                    usedQualityFallback = usedQualityFallback || result.usedQualityFallback
                }

                var groupedForm = finalForms.first ?? firstRequestForm
                groupedForm.prompt = finalForms
                    .map { $0.prompt.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .joined(separator: "\n\n--- Random model request ---\n\n")
                groupedForm.imageCount = payloads.count

                let job = try galleryStore.addJob(
                    form: groupedForm,
                    inputPrompt: inputPrompt,
                    payloads: payloads,
                    referenceImageCount: referenceURLs.count,
                    randomModelMode: randomModelMode,
                    randomPresetCategories: randomPresetCategories,
                    modelNames: modelNames,
                    modelSnapshots: modelSnapshots,
                        cameraSnapshot: cameraSnapshot,
                        presetSnapshots: presetSnapshots,
                        productSnapshot: productSnapshot,
                        adAngleSnapshot: adAngleSnapshot,
                        randomAdAngle: randomAdAngle,
                        promotionalContextSnapshot: promotionalContextSnapshot,
                        promotionalContextSnapshots: promotionalContextSnapshots,
                        randomPromotionalContext: randomPromotionalContext,
                        referenceImages: referenceSnapshots,
                        userReferenceImages: userReferenceImages
                )
                try? galleryStore.removePendingRecord(id: pendingBatch.id)
                removePendingGeneration(id: pendingBatch.id)
                selectedJobID = job.id
                statusMessage = usedQualityFallback
                    ? "Generated \(payloads.count) random-model image\(payloads.count == 1 ? "" : "s") using Low quality fallback."
                    : "Generated \(payloads.count) random-model image\(payloads.count == 1 ? "" : "s")."
                lastError = nil
            } catch {
                removePendingGeneration(id: pendingBatch.id)
                try? galleryStore.removePendingRecord(id: pendingBatch.id)
                var failedForm = firstRequestForm
                failedForm.prompt = requestForms
                    .map { $0.prompt.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .joined(separator: "\n\n--- Random model request ---\n\n")
                failedForm.imageCount = requestForms.count

                let failedJob = try? galleryStore.addFailedJob(
                    form: failedForm,
                    inputPrompt: inputPrompt,
                    failureMessage: error.localizedDescription,
                    referenceImageCount: referenceURLs.count,
                    randomModelMode: randomModelMode,
                    randomPresetCategories: randomPresetCategories,
                    modelNames: modelNames,
                    modelSnapshots: modelSnapshots,
                        cameraSnapshot: cameraSnapshot,
                        presetSnapshots: presetSnapshots,
                        productSnapshot: productSnapshot,
                        adAngleSnapshot: adAngleSnapshot,
                        randomAdAngle: randomAdAngle,
                        promotionalContextSnapshot: promotionalContextSnapshot,
                        promotionalContextSnapshots: promotionalContextSnapshots,
                        randomPromotionalContext: randomPromotionalContext,
                        referenceImages: referenceSnapshots,
                        userReferenceImages: userReferenceImages
                )
                if let failedJob {
                    selectedJobID = failedJob.id
                }
                lastError = error.localizedDescription
                statusMessage = pendingGenerations.isEmpty ? "Generation failed." : "One generation failed."
            }
        }
    }

    private func queueGeneration(
        apiKey: String,
        requestForm: GenerationForm,
        inputPrompt: String,
        referenceURLs: [URL],
        referenceSnapshots: [GenerationReferenceImageSnapshot],
        modelNames: [String],
        modelSnapshots: [GenerationModelSnapshot],
        cameraSnapshot: GenerationCameraSnapshot?,
        presetSnapshots: [GenerationPresetSnapshot],
        randomModelMode: RandomModelMode,
        randomPresetCategories: [PromptPresetCategory],
        productSnapshot: GenerationProductSnapshot?,
        adAngleSnapshot: GenerationAdAngleSnapshot?,
        randomAdAngle: Bool,
        promotionalContextSnapshot: GenerationPromotionalContextSnapshot?,
        promotionalContextSnapshots: [GenerationPromotionalContextSnapshot] = [],
        randomPromotionalContext: Bool,
        userReferenceImages: [GenerationReferenceImageSnapshot],
        galleryStore: GalleryStore
    ) {
        let pendingBatch = PendingGenerationBatch(
            prompt: requestForm.prompt,
            promptWithJSONs: requestForm.prompt,
            imageModel: requestForm.imageModel,
            quality: requestForm.quality,
            resolution: requestForm.resolution,
            geminiAspectRatio: requestForm.geminiAspectRatio,
            geminiImageSize: requestForm.geminiImageSize,
            imageCount: requestForm.sanitizedImageCount,
            outputFormat: requestForm.outputFormat,
            shotMode: requestForm.shotMode,
            audience: requestForm.audience,
            randomModelMode: randomModelMode,
            randomPresetCategories: randomPresetCategories,
            modelSnapshots: modelSnapshots,
            cameraSnapshot: cameraSnapshot,
            presetSnapshots: presetSnapshots,
            productSnapshot: productSnapshot,
            adAngleSnapshot: adAngleSnapshot,
            randomAdAngle: randomAdAngle,
            promotionalContextSnapshot: promotionalContextSnapshot,
            promotionalContextSnapshots: promotionalContextSnapshots,
            randomPromotionalContext: randomPromotionalContext,
            referenceImages: referenceSnapshots,
            userReferenceImages: userReferenceImages
        )

        try? galleryStore.addPendingRecord(
            id: pendingBatch.id,
            form: requestForm,
            inputPrompt: inputPrompt,
            referenceImageCount: referenceURLs.count,
            randomModelMode: randomModelMode,
            randomPresetCategories: randomPresetCategories,
            modelNames: modelNames,
            modelSnapshots: modelSnapshots,
            cameraSnapshot: cameraSnapshot,
            presetSnapshots: presetSnapshots,
            productSnapshot: productSnapshot,
            adAngleSnapshot: adAngleSnapshot,
            randomAdAngle: randomAdAngle,
            promotionalContextSnapshot: promotionalContextSnapshot,
            promotionalContextSnapshots: promotionalContextSnapshots,
            randomPromotionalContext: randomPromotionalContext,
            referenceImages: referenceSnapshots,
            userReferenceImages: userReferenceImages
        )
        pendingGenerations.insert(pendingBatch, at: 0)

        Task {
            do {
                let result = try await generateWithRetry(
                    apiKey: apiKey,
                    form: requestForm,
                    referenceImageURLs: referenceURLs,
                    pendingID: pendingBatch.id,
                    requestIndex: 1,
                    requestTotal: 1
                )
                let job = try galleryStore.addJob(
                    form: result.form,
                    inputPrompt: inputPrompt,
                    payloads: result.payloads,
                    referenceImageCount: referenceURLs.count,
                    randomModelMode: randomModelMode,
                    randomPresetCategories: randomPresetCategories,
                    modelNames: modelNames,
                    modelSnapshots: modelSnapshots,
                    cameraSnapshot: cameraSnapshot,
                    presetSnapshots: presetSnapshots,
                    productSnapshot: productSnapshot,
                    adAngleSnapshot: adAngleSnapshot,
                    randomAdAngle: randomAdAngle,
                    promotionalContextSnapshot: promotionalContextSnapshot,
                    promotionalContextSnapshots: promotionalContextSnapshots,
                    randomPromotionalContext: randomPromotionalContext,
                    referenceImages: referenceSnapshots,
                    userReferenceImages: userReferenceImages
                )
                try? galleryStore.removePendingRecord(id: pendingBatch.id)
                removePendingGeneration(id: pendingBatch.id)
                selectedJobID = job.id
                statusMessage = result.usedQualityFallback
                    ? "Generated \(result.payloads.count) image\(result.payloads.count == 1 ? "" : "s") using Low quality fallback."
                    : "Generated \(result.payloads.count) image\(result.payloads.count == 1 ? "" : "s")."
                lastError = nil
            } catch {
                removePendingGeneration(id: pendingBatch.id)
                try? galleryStore.removePendingRecord(id: pendingBatch.id)
                let failedJob = try? galleryStore.addFailedJob(
                    form: requestForm,
                    inputPrompt: inputPrompt,
                    failureMessage: error.localizedDescription,
                    referenceImageCount: referenceURLs.count,
                    randomModelMode: randomModelMode,
                    randomPresetCategories: randomPresetCategories,
                    modelNames: modelNames,
                    modelSnapshots: modelSnapshots,
                        cameraSnapshot: cameraSnapshot,
                        presetSnapshots: presetSnapshots,
                        productSnapshot: productSnapshot,
                        adAngleSnapshot: adAngleSnapshot,
                        randomAdAngle: randomAdAngle,
                        promotionalContextSnapshot: promotionalContextSnapshot,
                        promotionalContextSnapshots: promotionalContextSnapshots,
                        randomPromotionalContext: randomPromotionalContext,
                        referenceImages: referenceSnapshots,
                        userReferenceImages: userReferenceImages
                )
                if let failedJob {
                    selectedJobID = failedJob.id
                }
                lastError = error.localizedDescription
                statusMessage = pendingGenerations.isEmpty ? "Generation failed." : "One generation failed."
            }
        }
    }

    func generate(
        using galleryStore: GalleryStore,
        modelStore: PromptModelStore,
        cameraStore: CameraProfileStore,
        productStore: ProductReferenceStore,
        adAngleStore: AdAngleStore,
        promotionalContextStore: PromotionalContextStore,
        presetStore: PromptPresetStore
    ) {
        generate(form: form, using: galleryStore, modelStore: modelStore, cameraStore: cameraStore, productStore: productStore, adAngleStore: adAngleStore, promotionalContextStore: promotionalContextStore, presetStore: presetStore)
    }

    func retry(job: GenerationJob, using galleryStore: GalleryStore) {
        do {
            var requestForm = GenerationForm()
            requestForm.prompt = job.prompt
            requestForm.shotMode = job.shotMode
            requestForm.audience = job.audience
            requestForm.imageModel = job.imageModel
            requestForm.quality = job.quality
            requestForm.resolution = job.resolution
            requestForm.geminiAspectRatio = job.geminiAspectRatio
            requestForm.geminiImageSize = job.geminiImageSize
            requestForm.imageCount = job.imageCount
            requestForm.outputFormat = job.outputFormat
            requestForm.moderation = job.moderation
            let trimmedAPIKey = try generationAPIKey(for: requestForm)

            let referenceURLs = job.referenceImages.map(referenceImageURL(for:))
            let pendingBatch = PendingGenerationBatch(
                prompt: requestForm.prompt,
                promptWithJSONs: requestForm.prompt,
                imageModel: requestForm.imageModel,
                quality: requestForm.quality,
                resolution: requestForm.resolution,
                geminiAspectRatio: requestForm.geminiAspectRatio,
                geminiImageSize: requestForm.geminiImageSize,
                imageCount: requestForm.sanitizedImageCount,
                outputFormat: requestForm.outputFormat,
                shotMode: requestForm.shotMode,
                audience: requestForm.audience,
                randomModelMode: job.randomModelMode,
                randomPresetCategories: job.randomPresetCategories,
                modelSnapshots: job.modelSnapshots,
                cameraSnapshot: job.cameraSnapshot,
                presetSnapshots: job.presetSnapshots,
                productSnapshot: job.productSnapshot,
                adAngleSnapshot: job.adAngleSnapshot,
                randomAdAngle: job.randomAdAngle,
                promotionalContextSnapshot: job.promotionalContextSnapshot,
                promotionalContextSnapshots: job.promotionalContextSnapshots,
                randomPromotionalContext: job.randomPromotionalContext,
                referenceImages: job.referenceImages,
                userReferenceImages: job.userReferenceImages
            )

            if job.isFailed {
                try galleryStore.delete(job: job)
            }

            try? galleryStore.addPendingRecord(
                id: pendingBatch.id,
                form: requestForm,
                inputPrompt: job.inputPrompt,
                referenceImageCount: referenceURLs.count,
                randomModelMode: job.randomModelMode,
                randomPresetCategories: job.randomPresetCategories,
                modelNames: job.modelNames,
                modelSnapshots: job.modelSnapshots,
                cameraSnapshot: job.cameraSnapshot,
                presetSnapshots: job.presetSnapshots,
                productSnapshot: job.productSnapshot,
                adAngleSnapshot: job.adAngleSnapshot,
                randomAdAngle: job.randomAdAngle,
                promotionalContextSnapshot: job.promotionalContextSnapshot,
                promotionalContextSnapshots: job.promotionalContextSnapshots,
                randomPromotionalContext: job.randomPromotionalContext,
                referenceImages: job.referenceImages,
                userReferenceImages: job.userReferenceImages
            )
            pendingGenerations.insert(pendingBatch, at: 0)
            syncGenerationState()
            statusMessage = "Retry queued."
            lastError = nil

            Task {
                do {
                    let result = try await generateWithRetry(
                        apiKey: trimmedAPIKey,
                        form: requestForm,
                        referenceImageURLs: referenceURLs,
                        pendingID: pendingBatch.id,
                        requestIndex: 1,
                        requestTotal: 1
                    )
                    let newJob = try galleryStore.addJob(
                        form: result.form,
                        inputPrompt: job.inputPrompt,
                        payloads: result.payloads,
                        referenceImageCount: referenceURLs.count,
                        randomModelMode: job.randomModelMode,
                        randomPresetCategories: job.randomPresetCategories,
                        modelNames: job.modelNames,
                        modelSnapshots: job.modelSnapshots,
                        cameraSnapshot: job.cameraSnapshot,
                        presetSnapshots: job.presetSnapshots,
                        productSnapshot: job.productSnapshot,
                        adAngleSnapshot: job.adAngleSnapshot,
                        randomAdAngle: job.randomAdAngle,
                        promotionalContextSnapshot: job.promotionalContextSnapshot,
                        promotionalContextSnapshots: job.promotionalContextSnapshots,
                        randomPromotionalContext: job.randomPromotionalContext,
                        referenceImages: job.referenceImages,
                        userReferenceImages: job.userReferenceImages
                    )
                    try? galleryStore.removePendingRecord(id: pendingBatch.id)
                    removePendingGeneration(id: pendingBatch.id)
                    selectedJobID = newJob.id
                    statusMessage = result.usedQualityFallback
                        ? "Retry generated \(result.payloads.count) image\(result.payloads.count == 1 ? "" : "s") using Low quality fallback."
                        : "Retry generated \(result.payloads.count) image\(result.payloads.count == 1 ? "" : "s")."
                    lastError = nil
                } catch {
                    removePendingGeneration(id: pendingBatch.id)
                    try? galleryStore.removePendingRecord(id: pendingBatch.id)
                    let failedJob = try? galleryStore.addFailedJob(
                        form: requestForm,
                        inputPrompt: job.inputPrompt,
                        failureMessage: error.localizedDescription,
                        referenceImageCount: referenceURLs.count,
                        randomModelMode: job.randomModelMode,
                        randomPresetCategories: job.randomPresetCategories,
                        modelNames: job.modelNames,
                        modelSnapshots: job.modelSnapshots,
                        cameraSnapshot: job.cameraSnapshot,
                        presetSnapshots: job.presetSnapshots,
                        productSnapshot: job.productSnapshot,
                        adAngleSnapshot: job.adAngleSnapshot,
                        randomAdAngle: job.randomAdAngle,
                        promotionalContextSnapshot: job.promotionalContextSnapshot,
                        promotionalContextSnapshots: job.promotionalContextSnapshots,
                        randomPromotionalContext: job.randomPromotionalContext,
                        referenceImages: job.referenceImages,
                        userReferenceImages: job.userReferenceImages
                    )
                    if let failedJob {
                        selectedJobID = failedJob.id
                    }
                    lastError = error.localizedDescription
                    statusMessage = pendingGenerations.isEmpty ? "Retry failed." : "One retry failed."
                }
            }
        } catch {
            lastError = error.localizedDescription
            statusMessage = "Retry failed."
        }
    }

    func export(job: GenerationJob, using galleryStore: GalleryStore) {
        do {
            let urls = try galleryStore.export(job: job)
            if !urls.isEmpty {
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            }
            statusMessage = "Exported \(urls.count) image\(urls.count == 1 ? "" : "s") to Downloads."
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func export(image: GalleryImage, using galleryStore: GalleryStore) {
        do {
            let url = try galleryStore.export(image: image)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            statusMessage = "Exported image to Downloads."
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func runAdLocalizationJobs(apiKey: String, outputDirectory: URL) async {
        let selectedMarkets = Set(adLocalizationJobs.map(\.language))
        let truthPacket: AdLocalizationTruthPacket?
        do {
            truthPacket = try await adLocalizationTruthService.fetch(
                for: selectedMarkets,
                product: selectedAdLocalizationProduct,
                audioChronicleURL: adLocalizationAudioChronicleURL
            )
            statusMessage = "Queued \(adLocalizationJobs.count) localized ad image\(adLocalizationJobs.count == 1 ? "" : "s") with live price, article truth, and QC."
        } catch {
            truthPacket = nil
            statusMessage = "Live truth fetch failed; preserving existing prices and titles."
        }

        let runnableJobs = adLocalizationJobs.filter { $0.status != .succeeded && $0.status != .skipped }
        await withTaskGroup(of: Void.self) { group in
            var iterator = runnableJobs.makeIterator()

            for _ in 0..<Self.adLocalizationConcurrencyLimit {
                guard let job = iterator.next() else {
                    break
                }
                group.addTask { [weak self] in
                    await self?.runSingleAdLocalizationJob(
                        jobID: job.id,
                        apiKey: apiKey,
                        outputDirectory: outputDirectory,
                        truthPacket: truthPacket
                    )
                }
            }

            while await group.next() != nil {
                guard let job = iterator.next() else {
                    continue
                }
                group.addTask { [weak self] in
                    await self?.runSingleAdLocalizationJob(
                        jobID: job.id,
                        apiKey: apiKey,
                        outputDirectory: outputDirectory,
                        truthPacket: truthPacket
                    )
                }
            }
        }

        isAdLocalizationRunning = false
        let failedCount = adLocalizationJobs.filter { $0.status == .failed }.count
        let succeededCount = adLocalizationJobs.filter { $0.status == .succeeded }.count
        let skippedCount = adLocalizationJobs.filter { $0.status == .skipped }.count
        statusMessage = failedCount == 0
            ? "Ad localization complete: \(succeededCount) image\(succeededCount == 1 ? "" : "s")\(skippedCount > 0 ? ", \(skippedCount) skipped" : "")."
            : "Ad localization complete with \(failedCount) failure\(failedCount == 1 ? "" : "s")."
        lastError = failedCount == 0 ? nil : "Some localized ads failed. Check the language list for details."
        sendAdLocalizationNotification(succeededCount: succeededCount, skippedCount: skippedCount, failedCount: failedCount)
    }

    private func runSingleAdLocalizationJob(
        jobID: UUID,
        apiKey: String,
        outputDirectory: URL,
        truthPacket: AdLocalizationTruthPacket?
    ) async {
        guard let index = adLocalizationJobs.firstIndex(where: { $0.id == jobID }) else {
            return
        }

        var job = adLocalizationJobs[index]
        adLocalizationJobs[index].status = .running
        adLocalizationJobs[index].updatedAt = .now
        persistAdLocalizationJobs()
        statusMessage = "Localizing \(job.sourceFileName) to \(job.language.title)..."

        do {
            let sourceURL = URL(fileURLWithPath: job.sourcePath)
            let outputURL = outputDirectory.appendingPathComponent(Self.outputFileName(for: sourceURL, language: job.language, outputFormat: form.outputFormat))
            if fileManager.fileExists(atPath: outputURL.path) {
                adLocalizationJobs[index].status = .succeeded
                adLocalizationJobs[index].outputPath = outputURL.path
                adLocalizationJobs[index].errorMessage = nil
                adLocalizationJobs[index].updatedAt = .now
                persistAdLocalizationJobs()
                return
            }

            let result = try await localizeAdWithRetry(
                apiKey: apiKey,
                sourceURL: sourceURL,
                language: job.language,
                outputFormat: form.outputFormat,
                truthPacket: truthPacket,
                attemptHandler: { [weak self] attempt in
                    Task { @MainActor in
                        guard let self,
                              let liveIndex = self.adLocalizationJobs.firstIndex(where: { $0.id == jobID }) else {
                            return
                        }
                        self.adLocalizationJobs[liveIndex].attemptCount = attempt
                        self.adLocalizationJobs[liveIndex].updatedAt = .now
                        self.persistAdLocalizationJobs()
                    }
                }
            )

            guard let liveIndex = adLocalizationJobs.firstIndex(where: { $0.id == jobID }) else {
                return
            }
            job = adLocalizationJobs[liveIndex]
            switch result {
            case .generated(let payload):
                try payload.data.write(to: outputURL, options: .atomic)
                adLocalizationJobs[liveIndex].status = .succeeded
                adLocalizationJobs[liveIndex].outputPath = outputURL.path
                adLocalizationJobs[liveIndex].errorMessage = nil
            case .skipped(let reason):
                adLocalizationJobs[liveIndex].status = .skipped
                adLocalizationJobs[liveIndex].outputPath = nil
                adLocalizationJobs[liveIndex].errorMessage = reason
            }
            adLocalizationJobs[liveIndex].updatedAt = .now
            persistAdLocalizationJobs()
        } catch {
            guard let liveIndex = adLocalizationJobs.firstIndex(where: { $0.id == jobID }) else {
                return
            }
            adLocalizationJobs[liveIndex].status = .failed
            adLocalizationJobs[liveIndex].errorMessage = error.localizedDescription
            adLocalizationJobs[liveIndex].updatedAt = .now
            persistAdLocalizationJobs()
        }
    }

    private func localizeAdWithRetry(
        apiKey: String,
        sourceURL: URL,
        language: AdLocalizationLanguage,
        outputFormat: OutputFormat,
        truthPacket: AdLocalizationTruthPacket?,
        attemptHandler: @escaping (Int) -> Void
    ) async throws -> AdLocalizationRunResult {
        var lastError: Error?
        let outputSize = Self.outputSize(for: sourceURL)
        let analysisTruthContext = truthPacket?.promptContext(
            for: language,
            includeComponentPriceMatches: false
        )
        let sourceIntent = try? await service.analyzeAdLocalizationSource(
            apiKey: apiKey,
            imageURL: sourceURL,
            language: language,
            truthContext: analysisTruthContext
        )
        if let sourceIntent,
           Self.shouldSkipEnglishCurrencyLocalization(language: language, sourceIntent: sourceIntent) {
            return .skipped("Skipped: no visible price, savings, percent-off, or currency-specific claim for \(language.title).")
        }
        let generationTruthContext = truthPacket?.promptContext(
            for: language,
            componentPriceFields: sourceIntent?.visibleComponentPriceFields ?? [],
            includeComponentPriceMatches: true
        )
        var qcFeedback: [String] = []

        for attempt in 1...Self.maxGenerationAttempts {
            attemptHandler(attempt)
            do {
                let attemptPrompt = Self.adLocalizationPrompt(
                    for: language,
                    truthContext: generationTruthContext,
                    sourceIntent: sourceIntent,
                    qcFeedback: qcFeedback
                )
                let payload = try await service.editImage(
                    apiKey: apiKey,
                    imageURL: sourceURL,
                    prompt: attemptPrompt,
                    model: ImageModelOption.preferredModel,
                    quality: .max,
                    size: outputSize,
                    outputFormat: outputFormat,
                    moderation: .low
                )

                let qcResult = try await service.validateAdLocalizationOutput(
                    apiKey: apiKey,
                    sourceURL: sourceURL,
                    outputData: payload.data,
                    language: language,
                    truthContext: generationTruthContext,
                    sourceIntent: sourceIntent ?? AdLocalizationSourceIntent.fallback
                )
                guard qcResult.pass else {
                    qcFeedback = qcResult.errors
                    throw AdLocalizationQCFailure(errors: qcResult.errors)
                }
                return .generated(payload)
            } catch {
                lastError = error
                guard attempt < Self.maxGenerationAttempts else {
                    break
                }
                try? await Task.sleep(nanoseconds: UInt64(3 * attempt) * 1_000_000_000)
            }
        }

        throw lastError ?? AppError.invalidResponse
    }

    private static func shouldSkipEnglishCurrencyLocalization(
        language: AdLocalizationLanguage,
        sourceIntent: AdLocalizationSourceIntent
    ) -> Bool {
        switch language {
        case .englishGBP, .englishAUD, .englishCAD:
            return !sourceIntent.hasCurrencySpecificLocalizationNeed
        case .englishUSD, .germanEUR, .frenchEUR, .spanishEUR, .italianEUR, .japaneseJPY, .koreanKRW:
            return false
        }
    }

    private func makeAdLocalizationJob(
        sourceURL: URL,
        language: AdLocalizationLanguage,
        outputDirectory: URL
    ) -> AdLocalizationJob {
        let outputURL = outputDirectory.appendingPathComponent(Self.outputFileName(for: sourceURL, language: language, outputFormat: form.outputFormat))
        if fileManager.fileExists(atPath: outputURL.path) {
            return AdLocalizationJob(
                sourceURL: sourceURL,
                language: language,
                status: .succeeded,
                outputPath: outputURL.path,
                updatedAt: .now
            )
        }

        return AdLocalizationJob(sourceURL: sourceURL, language: language)
    }

    private static func adLocalizationPrompt(
        for language: AdLocalizationLanguage,
        truthContext: String?,
        sourceIntent: AdLocalizationSourceIntent?,
        qcFeedback: [String]
    ) -> String {
        """
        Localize this static Meta ad into \(language.localeName).

        Preserve the original ad as closely as possible:
        - Keep the product, photography, illustration style, composition, crop, aspect ratio, colors, logos, offer structure, and visual hierarchy intact.
        - Only change visible ad text that needs localization.
        - Keep brand names, product names, trademarks, promo codes, and legal marks unchanged unless grammar around them needs to change.
        - Use the live truth packet below as replacement truth for Soundbrenner prices, compare-at prices, discounts, currency symbols, shipping, and Audio Chronicle article names/URLs.
        - Do not add offer elements that are not already present in the source image. If the source shows only a discount, keep only a discount. If it shows only an amount-off claim, keep only an amount-off claim. If it does not show a shipping threshold, do not add a threshold.
        - Do not add a compare-at/original price unless the source image already has a visible compare-at/original price.
        - Do not add shipping text unless the source image already has visible shipping text.
        - Convert prices only when the live truth packet gives an exact target-market value for the product. Do not invent currency conversions.
        - If the source image has a visible percent-off claim, replace it with the exact percent-off truth from the live truth packet. Do not invent or preserve stale percent discounts.
        - If locale phrase guidance uses {percent}, replace it with the live numeric percent. Never render {percent} literally.
        - For percent-off claims, localize the offer words around the number. In non-English outputs, do not leave English words such as OFF, SITE WIDE, SALE, or UP TO visible; only the digits and % sign may carry over unchanged.
        - If the source image has itemized bundle component/accessory prices, use the component price truth table to replace matching USD prices with target-market prices. Keep FREE/free claims present when they are visible in the source.
        - English target markets still require price localization. For English + CAD/AUD/GBP, do not copy through USD source amounts; replace them with the exact target-market amount and currency display from the live truth packet.
        - Rewrite the copy idiomatically for \(language.localeName), not word-for-word, so it reads like an effective native performance ad.
        - Match the original meaning, urgency, and persuasive intent.
        - Fit the localized text into the same approximate text boxes. Use concise native copy where the target language is longer.
        - Do not invent new claims, discounts, products, badges, UI elements, people, or backgrounds.
        - Do not translate the Soundbrenner brand name.

        \(truthContext ?? "Live truth packet unavailable. Preserve existing prices and Audio Chronicle titles rather than guessing.")

        \(sourceIntent?.promptContext ?? "Source intent analysis unavailable. Be conservative and only replace clearly visible source text.")

        \(qcFeedback.isEmpty ? "" : "Previous QC attempt failed. Fix these issues exactly:\n- \(qcFeedback.joined(separator: "\n- "))")

        \(language.phraseGuidance)

        Do not leave English ad copy visible unless it is a brand name, product name, URL, promo code, exact price, number, or currency symbol.

        Return the finished localized ad only.
        """
    }

    private static func outputFileName(for sourceURL: URL, language: AdLocalizationLanguage, outputFormat: OutputFormat) -> String {
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        return "\(baseName)-\(language.outputCode).\(outputFormat.rawValue)"
    }

    private static func imageFiles(in folderURL: URL, fileManager: FileManager) throws -> [URL] {
        let imageExtensions = Set(["png", "jpg", "jpeg", "webp", "heic", "tif", "tiff"])
        return try fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter { imageExtensions.contains($0.pathExtension.lowercased()) }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private static func outputSize(for sourceURL: URL) -> String {
        guard let image = NSImage(contentsOf: sourceURL),
              let representation = image.representations.first(where: { $0.pixelsWide > 0 && $0.pixelsHigh > 0 }) else {
            return ResolutionPreset.landscape2k.sizeValue
        }

        let width = validImageDimension(representation.pixelsWide)
        let height = validImageDimension(representation.pixelsHigh)
        return "\(width)x\(height)"
    }

    private static func validImageDimension(_ value: Int) -> Int {
        let rounded = Int((Double(value) / 16.0).rounded()) * 16
        return min(max(rounded, 16), 3840)
    }

    private func persistAdLocalizationJobs() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(adLocalizationJobs)
            try data.write(to: adLocalizationJobsURL, options: .atomic)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func persistAdLocalizationLanguages() {
        guard !isRestoringPreferences else {
            return
        }

        UserDefaults.standard.set(
            selectedAdLocalizationLanguages.map(\.rawValue),
            forKey: Self.selectedAdLocalizationLanguagesKey
        )
    }

    private func persistAdLocalizationProduct() {
        guard !isRestoringPreferences else {
            return
        }

        UserDefaults.standard.set(
            selectedAdLocalizationProduct.rawValue,
            forKey: Self.selectedAdLocalizationProductKey
        )
    }

    private func persistAdLocalizationAudioChronicleURL() {
        guard !isRestoringPreferences else {
            return
        }

        UserDefaults.standard.set(
            adLocalizationAudioChronicleURL.trimmingCharacters(in: .whitespacesAndNewlines),
            forKey: Self.adLocalizationAudioChronicleURLKey
        )
    }

    private func sendAdLocalizationNotification(succeededCount: Int, skippedCount: Int, failedCount: Int) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { isAllowed, _ in
            guard isAllowed else {
                return
            }

            let content = UNMutableNotificationContent()
            content.title = "Soundbrenner Pixel"
            content.body = failedCount == 0
                ? "Ad localization complete: \(succeededCount) image\(succeededCount == 1 ? "" : "s")\(skippedCount > 0 ? ", \(skippedCount) skipped" : "")."
                : "Ad localization finished with \(failedCount) failure\(failedCount == 1 ? "" : "s")."
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "ad-localization-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            center.add(request)
        }
    }

    private func resolvedModelBatches(from modelStore: PromptModelStore, imageCount: Int) throws -> [[PromptModelProfile]] {
        if randomModelMode != .none {
            let usableProfiles = modelStore.profiles.filter { profile in
                isUsableModel(profile, in: modelStore) && randomModelMode.includes(profile)
            }
            guard !usableProfiles.isEmpty else {
                if modelStore.profiles.isEmpty {
                    return Array(repeating: [], count: imageCount)
                }
                throw AppError.invalidModelJSON("random model selection")
            }

            var shuffledProfiles = usableProfiles.shuffled()
            let batches = (0..<imageCount).map { index in
                if index > 0, index.isMultiple(of: shuffledProfiles.count) {
                    shuffledProfiles.shuffle()
                }

                return [shuffledProfiles[index % shuffledProfiles.count]]
            }

            return batches
        }

        let profiles = selectedModelIDs
            .compactMap(modelStore.profile(with:))

        for profile in profiles {
            if !FileManager.default.fileExists(atPath: modelStore.thumbnailURL(for: profile).path) {
                throw AppError.missingModelThumbnail(profile.name)
            }
            try PromptModelStore.validateJSON(profile.promptJSON, label: profile.name)
        }

        if profiles.count > 1 {
            return (0..<imageCount).map { index in
                [profiles[index % profiles.count]]
            }
        }

        return [profiles]
    }

    private func isUsableModel(_ profile: PromptModelProfile, in modelStore: PromptModelStore) -> Bool {
        FileManager.default.fileExists(atPath: modelStore.thumbnailURL(for: profile).path)
            && (try? PromptModelStore.validateJSON(profile.promptJSON, label: profile.name)) != nil
    }

    private func resolvedSelectedCamera(from cameraStore: CameraProfileStore, form: GenerationForm) throws -> CameraProfile? {
        guard let selectedCameraID else {
            try validateCameraJSON(form: form)
            return nil
        }

        guard let profile = cameraStore.profile(with: selectedCameraID) else {
            return nil
        }

        try PromptModelStore.validateJSON(profile.promptJSON, label: profile.name)
        return profile
    }

    private func resolvedSelectedProduct(from productStore: ProductReferenceStore, form: GenerationForm) throws -> ProductReferenceProfile? {
        guard let product = productStore.product(with: selectedProductID) else {
            return nil
        }

        guard product.applies(to: form.shotMode) else {
            return nil
        }

        let productJSON = product.normalizedPromptJSON
        if !productJSON.isEmpty {
            try PromptModelStore.validateJSON(productJSON, label: product.name)
        }

        return product
    }

    private func resolvedSelectedAdAngles(from adAngleStore: AdAngleStore) throws -> [AdAngleProfile] {
        guard !useRandomAdAngle else {
            return []
        }

        return try selectedAdAngleIDs.compactMap { id in
            guard let adAngle = adAngleStore.adAngle(with: id) else {
                return nil
            }

            try PromptModelStore.validateJSON(adAngle.promptJSON, label: adAngle.name)
            return adAngle
        }
    }

    private func resolvedSelectedPromotionalContexts(from promotionalContextStore: PromotionalContextStore) throws -> [PromotionalContextProfile] {
        guard !useRandomPromotionalContext else {
            return []
        }

        return try selectedPromotionalContextIDs.compactMap { id in
            guard let promotionalContext = promotionalContextStore.promotionalContext(with: id) else {
                return nil
            }

            try PromptModelStore.validateJSON(promotionalContext.promptJSON, label: promotionalContext.name)
            return promotionalContext
        }
    }

    private func resolvedSelectedPresets(from presetStore: PromptPresetStore, shotMode: ShotMode, audience: AudienceKind) throws -> [PromptPresetProfile] {
        try PromptPresetCategory.allCases.flatMap { category in
            guard category.applies(to: shotMode),
                  !randomPresetCategories.contains(category),
                  let presetIDs = selectedPresetIDs[category] else {
                return [PromptPresetProfile]()
            }

            return try presetIDs.compactMap { presetID in
                guard let preset = presetStore.profile(with: presetID),
                      preset.shotMode == nil || preset.shotMode == shotMode,
                      preset.applies(to: audience, in: shotMode) else {
                    return nil
                }

                try PromptModelStore.validateJSON(preset.promptJSON, label: preset.name)
                return preset
            }
        }
    }

    private func resolvedPresetsForRequest(
        from presetStore: PromptPresetStore,
        shotMode: ShotMode,
        audience: AudienceKind,
        fixedPresets: [PromptPresetProfile],
        imageIndex: Int
    ) throws -> [PromptPresetProfile] {
        var presetsByCategory = [PromptPresetCategory: PromptPresetProfile]()
        for (category, presets) in Dictionary(grouping: fixedPresets, by: \.category) {
            guard !presets.isEmpty else {
                continue
            }
            presetsByCategory[category] = presets[imageIndex % presets.count]
        }

        for category in randomPresetCategories where category.applies(to: shotMode) {
            let candidates = presetStore.profiles(
                for: category,
                shotMode: shotMode,
                audience: shotMode.usesAudienceSelection ? audience : nil
            )
            if let preset = candidates.randomElement() {
                try PromptModelStore.validateJSON(preset.promptJSON, label: preset.name)
                presetsByCategory[category] = preset
            }
        }

        return PromptPresetCategory.allCases.compactMap { presetsByCategory[$0] }
    }

    private func resolvedAdAngleForRequest(
        selectedAdAngles: [AdAngleProfile],
        adAngleStore: AdAngleStore,
        imageIndex: Int,
        useRandom: Bool
    ) -> AdAngleProfile? {
        if useRandom {
            return adAngleStore.adAngles.randomElement()
        }

        guard !selectedAdAngles.isEmpty else {
            return nil
        }

        return selectedAdAngles[imageIndex % selectedAdAngles.count]
    }

    private func makeSetupSnapshot(presets: [String]) -> GenerationCameraSnapshot? {
        guard !presets.isEmpty else {
            return nil
        }

        return GenerationCameraSnapshot(name: presets.joined(separator: " + "))
    }

    private func makeSetupSnapshot(adAngles: [String]) -> GenerationAdAngleSnapshot? {
        guard !adAngles.isEmpty else {
            return nil
        }

        let uniqueNames = Array(NSOrderedSet(array: adAngles).array.compactMap { $0 as? String })
        if uniqueNames.count == 1 {
            return GenerationAdAngleSnapshot(name: uniqueNames[0])
        }

        return GenerationAdAngleSnapshot(name: "\(uniqueNames.count) random ad angles")
    }

    private func makeSetupSnapshot(promotionalContexts: [String]) -> GenerationPromotionalContextSnapshot? {
        guard !promotionalContexts.isEmpty else {
            return nil
        }

        let uniqueNames = Array(NSOrderedSet(array: promotionalContexts).array.compactMap { $0 as? String })
        if uniqueNames.count == 1 {
            return GenerationPromotionalContextSnapshot(name: uniqueNames[0])
        }

        return GenerationPromotionalContextSnapshot(name: "\(uniqueNames.count) random promotional contexts")
    }

    private func buildPrompt(
        form: GenerationForm,
        with models: [PromptModelProfile],
        productProfile: ProductReferenceProfile?,
        adAngleProfile: AdAngleProfile?,
        promotionalContextProfiles: [PromotionalContextProfile],
        presets: [PromptPresetProfile]
    ) -> String {
        let basePrompt = form.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let productJSON = productProfile?.normalizedPromptJSON ?? ""
        let adAngleJSON = adAngleProfile?.normalizedPromptJSON ?? ""
        let promotionalContextJSON = promotionalContextProfiles
            .map(\.normalizedPromptJSON)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        var sections = [String]()

        if !basePrompt.isEmpty {
            sections.append(basePrompt)
        }

        sections.append(Self.referenceLikenessSafetyRule)

        if !models.isEmpty {
            let jsonBlocks = models
                .map(\.normalizedPromptJSON)
                .joined(separator: "\n\n")

            sections.append(
                """
                Attached model metadata JSON:
                \(jsonBlocks)
                """
            )
        }

        if !productJSON.isEmpty {
            sections.append(
                """
                Attached product reference JSON:
                \(productJSON)
                """
            )
        }

        if !adAngleJSON.isEmpty {
            sections.append(
                """
                Attached ad angle JSON:
                \(adAngleJSON)
                """
            )
        }

        if !promotionalContextJSON.isEmpty {
            sections.append(
                """
                Attached promotional context JSON\(promotionalContextProfiles.count == 1 ? "" : "s"):
                \(promotionalContextJSON)
                """
            )
        }

        sections.append(
            """
            Shot mode:
            \(form.shotMode.title). \(form.shotMode.subtitle)
            """
        )

        if form.shotMode == .productOnWhite {
            sections.append(
                """
                Product-on-white requirement:
                Create a clean image on a pure white seamless background. Default to a product-only ecommerce shot; only include hands when the selected composition metadata explicitly asks for hand-held product photography. Do not include a full model, face, lifestyle environment, desk, props, or colored background.
                """
            )
        }

        for preset in presets {
            sections.append(
                """
                \(preset.category.title) metadata JSON:
                \(preset.normalizedPromptJSON)
                """
            )
        }

        return sections.joined(separator: "\n\n")
    }

    private func validateCameraJSON(form: GenerationForm) throws {
        let trimmed = form.cameraJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        guard let data = trimmed.data(using: .utf8) else {
            throw AppError.invalidCameraJSON
        }
        _ = try JSONSerialization.jsonObject(with: data)
    }

    func referenceImageURL(for snapshot: GenerationReferenceImageSnapshot) -> URL {
        referenceImagesDirectoryURL.appendingPathComponent(snapshot.fileName)
    }

    private func buildReferenceURLs(productProfile: ProductReferenceProfile?, adAngleProfile: AdAngleProfile?, promotionalContextProfiles: [PromotionalContextProfile]) throws -> [URL] {
        var importCache = [String: URL]()
        return try buildReferenceURLs(
            productProfile: productProfile,
            adAngleProfile: adAngleProfile,
            promotionalContextProfiles: promotionalContextProfiles,
            importCache: &importCache
        )
    }

    private func buildReferenceURLs(
        productProfile: ProductReferenceProfile?,
        adAngleProfile: AdAngleProfile?,
        promotionalContextProfiles: [PromotionalContextProfile],
        importCache: inout [String: URL]
    ) throws -> [URL] {
        let manualReferenceURLs = uniqueURLs(Array(NSOrderedSet(array: referenceImageURLs).array.compactMap { $0 as? URL }))
        let importedURLs = try manualReferenceURLs.map { try importReferenceImage($0, cache: &importCache) }
        referenceImageURLs = importedURLs
        let importedProductReferenceURLs = try uniqueURLs(productProfile?.referenceImageURLs ?? []).map { try importReferenceImage($0, cache: &importCache) }
        let importedAdAngleReferenceURLs = try uniqueURLs(adAngleProfile?.referenceImageURLs ?? []).map { try importReferenceImage($0, cache: &importCache) }
        let promotionalContextReferenceURLs = promotionalContextProfiles.flatMap(\.referenceImageURLs)
        let importedPromotionalContextReferenceURLs = try uniqueURLs(promotionalContextReferenceURLs).map { try importReferenceImage($0, cache: &importCache) }
        return uniqueURLs(importedProductReferenceURLs + importedAdAngleReferenceURLs + importedPromotionalContextReferenceURLs + importedURLs)
    }

    private func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { url in
            let path = url.standardizedFileURL.path
            guard !seen.contains(path) else {
                return false
            }
            seen.insert(path)
            return true
        }
    }

    private func importReferenceImage(_ sourceURL: URL) throws -> URL {
        if sourceURL.deletingLastPathComponent() == referenceImagesDirectoryURL {
            guard fileManager.fileExists(atPath: sourceURL.path) else {
                throw AppError.apiError("Reference photo could not be found: \(sourceURL.lastPathComponent)")
            }
            return sourceURL
        }

        let originalName = sourceURL.lastPathComponent
        let safeOriginalName = originalName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let destinationURL = referenceImagesDirectoryURL.appendingPathComponent("\(UUID().uuidString)-\(safeOriginalName)")
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }

    private func importReferenceImage(_ sourceURL: URL, cache: inout [String: URL]) throws -> URL {
        let cacheKey = sourceURL.standardizedFileURL.path
        if let cachedURL = cache[cacheKey] {
            guard fileManager.fileExists(atPath: cachedURL.path) else {
                cache.removeValue(forKey: cacheKey)
                return try importReferenceImage(sourceURL, cache: &cache)
            }
            return cachedURL
        }

        let importedURL = try importReferenceImage(sourceURL)
        cache[cacheKey] = importedURL
        return importedURL
    }

    private func makeReferenceSnapshots(from urls: [URL]) -> [GenerationReferenceImageSnapshot] {
        uniqueReferenceSnapshots(urls.map {
            GenerationReferenceImageSnapshot(
                originalFileName: $0.lastPathComponent,
                fileName: $0.lastPathComponent
            )
        })
    }

    private func uniqueReferenceSnapshots(_ snapshots: [GenerationReferenceImageSnapshot]) -> [GenerationReferenceImageSnapshot] {
        var seen = Set<String>()
        return snapshots.filter { snapshot in
            guard !seen.contains(snapshot.fileName) else {
                return false
            }
            seen.insert(snapshot.fileName)
            return true
        }
    }

    private static func referenceImagesDirectory() -> URL {
        let fileManager = FileManager.default
        let base = try! fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = base
            .appendingPathComponent("SoundbrennerMediaGenerator", isDirectory: true)
            .appendingPathComponent("ReferenceImages", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func appSupportFile(named fileName: String) -> URL {
        let fileManager = FileManager.default
        let base = try! fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = base.appendingPathComponent("SoundbrennerMediaGenerator", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(fileName)
    }

    private static func loadAdLocalizationJobs(from url: URL) -> [AdLocalizationJob] {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let jobs = (try? decoder.decode([AdLocalizationJob].self, from: data)) ?? []
        return jobs.map { job in
            var recoveredJob = job
            if recoveredJob.status == .running || recoveredJob.status == .queued {
                recoveredJob.status = .failed
                recoveredJob.errorMessage = "Localization was interrupted before this image finished."
                recoveredJob.updatedAt = .now
            }
            return recoveredJob
        }
    }

    private static func loadAdLocalizationLanguages() -> Set<AdLocalizationLanguage> {
        let rawValues = UserDefaults.standard.stringArray(forKey: selectedAdLocalizationLanguagesKey) ?? []
        let supportedLanguages = Set(AdLocalizationLanguage.allCases)
        let languages = Set(rawValues.compactMap(AdLocalizationLanguage.init(rawValue:))).intersection(supportedLanguages)
        return languages.isEmpty ? [.germanEUR] : languages
    }

    private static func loadAdLocalizationProduct() -> AdLocalizationProduct {
        guard let rawValue = UserDefaults.standard.string(forKey: selectedAdLocalizationProductKey),
              let product = AdLocalizationProduct(rawValue: rawValue) else {
            return .none
        }
        return product
    }

    private static func loadAdLocalizationAudioChronicleURL() -> String {
        UserDefaults.standard.string(forKey: adLocalizationAudioChronicleURLKey) ?? ""
    }

    private static func loadAdLocalizationFolderURL() -> URL? {
        guard let bookmarkData = UserDefaults.standard.data(forKey: adLocalizationFolderBookmarkKey) else {
            return nil
        }

        var isStale = false
        guard let resolvedURL = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }

        _ = resolvedURL.startAccessingSecurityScopedResource()
        if isStale,
           let refreshedData = try? resolvedURL.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
           ) {
            UserDefaults.standard.set(refreshedData, forKey: adLocalizationFolderBookmarkKey)
        }
        return resolvedURL
    }

    private func generationAPIKey(for form: GenerationForm) throws -> String {
        if form.imageModel.isGeminiImageModel {
            let trimmedKey = geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedKey.isEmpty else {
                throw AppError.missingGeminiAPIKey
            }
            return trimmedKey
        }

        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw AppError.missingAPIKey
        }
        return trimmedKey
    }

    private func generateWithRetry(
        apiKey: String,
        form: GenerationForm,
        referenceImageURLs: [URL],
        pendingID: UUID?,
        requestIndex: Int,
        requestTotal: Int
    ) async throws -> ImageGenerationResult {
        var lastError: Error?
        var workingForm = form
        var usedQualityFallback = false

        for attempt in 1...Self.maxGenerationAttempts {
            do {
                let requestPrefix = requestTotal > 1 ? "Request \(requestIndex)/\(requestTotal) · " : ""
                let referenceText = referenceImageURLs.isEmpty ? "no reference photos" : "\(referenceImageURLs.count) reference photo\(referenceImageURLs.count == 1 ? "" : "s")"
                if attempt == 1 {
                    statusMessage = "Generating image\(workingForm.sanitizedImageCount == 1 ? "" : "s")..."
                } else {
                    statusMessage = "Retrying generation after timeout (\(attempt)/\(Self.maxGenerationAttempts))..."
                }
                if let pendingID {
                    let providerName = workingForm.imageModel.isGeminiImageModel
                        ? "Nano Banana Pro"
                        : "OpenAI"
                    updatePendingGeneration(
                        id: pendingID,
                        status: "Attempt \(attempt)/\(Self.maxGenerationAttempts)",
                        detail: "\(requestPrefix)Waiting for \(providerName) image generation. \(workingForm.imageModel.isGeminiImageModel ? "\(workingForm.geminiImageSize.rawValue) \(workingForm.geminiAspectRatio.rawValue)" : workingForm.resolution.title), \(referenceText)."
                    )
                }

                let payloads = if workingForm.imageModel.isGeminiImageModel {
                    try await geminiService.generateImages(
                        apiKey: apiKey,
                        form: workingForm,
                        referenceImageURLs: referenceImageURLs
                    )
                } else {
                    try await service.generateImages(
                        apiKey: apiKey,
                        form: workingForm,
                        referenceImageURLs: referenceImageURLs
                    )
                }
                return ImageGenerationResult(
                    payloads: payloads,
                    form: workingForm,
                    usedQualityFallback: usedQualityFallback
                )
            } catch let error as AppError where error.isRetriableGenerationTransportError {
                lastError = error

                if !workingForm.imageModel.isGeminiImageModel,
                   !referenceImageURLs.isEmpty,
                   workingForm.quality != .low,
                   !usedQualityFallback {
                    workingForm.quality = .low
                    usedQualityFallback = true
                    statusMessage = "\(error.retryStatusPrefix) Retrying reference edit at Low quality..."
                    if let pendingID {
                        updatePendingGeneration(
                            id: pendingID,
                            status: "Retrying",
                            detail: "\(error.retryStatusPrefix) Reference edit failed at higher quality, retrying once at Low quality."
                        )
                    }
                    continue
                }

                guard attempt < Self.maxGenerationAttempts else {
                    if let pendingID {
                        updatePendingGeneration(
                            id: pendingID,
                            status: "Failed",
                            detail: "\(error.retryStatusPrefix) No attempts left."
                        )
                    }
                    throw error
                }

                let delaySeconds = UInt64(3 * attempt)
                statusMessage = "\(error.retryStatusPrefix) Retrying in \(delaySeconds)s (\(attempt + 1)/\(Self.maxGenerationAttempts))..."
                if let pendingID {
                    updatePendingGeneration(
                        id: pendingID,
                        status: "Retrying in \(delaySeconds)s",
                        detail: "\(error.retryStatusPrefix) Attempt \(attempt) failed. Next attempt: \(attempt + 1)/\(Self.maxGenerationAttempts)."
                    )
                }
                try? await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
            } catch {
                if let pendingID {
                    updatePendingGeneration(
                        id: pendingID,
                        status: "Failed",
                        detail: error.localizedDescription
                    )
                }
                throw error
            }
        }

        throw lastError ?? AppError.invalidResponse
    }

    private func updatePendingGeneration(id: UUID, status: String, detail: String) {
        guard let index = pendingGenerations.firstIndex(where: { $0.id == id }) else {
            return
        }
        pendingGenerations[index].statusMessage = status
        pendingGenerations[index].detailMessage = detail
        pendingGenerations[index].updatedAt = .now
    }

    private func removePendingGeneration(id: UUID) {
        pendingGenerations.removeAll { $0.id == id }
        syncGenerationState()
    }

    private func syncGenerationState() {
        isGenerating = !pendingGenerations.isEmpty
    }

    private func persistPreferences() {
        guard !isRestoringPreferences else {
            return
        }
        preferences.saveForm(form)
        preferences.saveSelectedModelIDs(selectedModelIDs)
        preferences.saveRandomModelMode(randomModelMode)
        preferences.saveSelectedCameraID(selectedCameraID)
        preferences.saveSelectedProductID(selectedProductID)
        preferences.saveSelectedAdAngleIDs(selectedAdAngleIDs)
        preferences.saveRandomAdAngle(useRandomAdAngle)
        preferences.saveSelectedPromotionalContextIDs(selectedPromotionalContextIDs)
        preferences.saveRandomPromotionalContext(false)
        preferences.saveSelectedPresetIDLists(selectedPresetIDs)
        preferences.saveRandomPresetCategories(randomPresetCategories)
    }

    private func scheduleFormPersistence() {
        guard !isRestoringPreferences else {
            return
        }

        pendingFormPersistenceTask?.cancel()
        pendingFormPersistenceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.formPersistenceDebounceNanoseconds)
            guard !Task.isCancelled, let self else {
                return
            }
            self.persistPreferences()
        }
    }
}

private extension AppError {
    var isRetriableGenerationTransportError: Bool {
        switch self {
        case .requestTimedOut, .networkConnectionLost:
            true
        default:
            false
        }
    }

    var retryStatusPrefix: String {
        switch self {
        case .requestTimedOut:
            "Generation timed out."
        case .networkConnectionLost:
            "Connection dropped."
        default:
            "Generation failed."
        }
    }
}

private extension URLError.Code {
    var isTransientConnectionFailure: Bool {
        switch self {
        case .networkConnectionLost,
             .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed,
             .notConnectedToInternet,
             .timedOut:
            return true
        default:
            return false
        }
    }
}

private extension Data {
    mutating func appendString(_ string: String) {
        append(Data(string.utf8))
    }
}
