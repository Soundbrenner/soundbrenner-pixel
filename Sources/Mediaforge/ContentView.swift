import AppKit
import ImageIO
import UniformTypeIdentifiers
import SwiftUI

private extension Color {
    // The light gradient stop in Mediaforge.icon, #FAF5E9 in sRGB.
    static let mediaforgeCream = Color(red: 250 / 255, green: 245 / 255, blue: 233 / 255)
    static let mediaforgeCreamHovered = Color(red: 230 / 255, green: 211 / 255, blue: 175 / 255)
    static let mediaforgeAccent = Color(nsColor: NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(srgbRed: 232 / 255, green: 220 / 255, blue: 199 / 255, alpha: 1)
        }
        return NSColor(srgbRed: 117 / 255, green: 86 / 255, blue: 47 / 255, alpha: 1)
    })
}

private struct MediaforgeActionStyle: PrimitiveButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.appearsActive) private var appearsActive
    @State private var isLegacyButtonHovered = false

    func makeBody(configuration: Configuration) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                Button(role: configuration.role, action: configuration.trigger) {
                    configuration.label.foregroundStyle(
                        isEnabled ? (appearsActive ? Color.black : Color.primary) : Color.secondary
                    )
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .tint(.mediaforgeCream)
                .modifier(ColoredGlassHover())
            } else {
                Button(role: configuration.role, action: configuration.trigger) {
                    configuration.label.foregroundStyle(isEnabled ? Color.primary : Color.secondary)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .tint(.clear)
            }
        } else if prominent {
            Button(role: configuration.role, action: configuration.trigger) {
                configuration.label
                    .foregroundStyle(isEnabled ? Color.black : Color.secondary)
            }
            .buttonStyle(.borderedProminent)
            .tint(isEnabled && appearsActive && isLegacyButtonHovered ? .mediaforgeCreamHovered : .mediaforgeCream)
            .onHover { isLegacyButtonHovered = $0 }
        } else {
            Button(role: configuration.role, action: configuration.trigger) {
                configuration.label
            }
            .buttonStyle(.bordered)
        }
    }
}

private struct ColoredGlassHover: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    private var showsHighlight: Bool { isHovered && isEnabled }

    func body(content: Content) -> some View {
        content
            .overlay {
                Capsule().fill(Color.black.opacity(showsHighlight ? 0.07 : 0))
                    .allowsHitTesting(false)
            }
            .onHover { isHovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: showsHighlight)
    }
}

private struct GeneratorFooterPlacement<Footer: View>: ViewModifier {
    let footer: Footer

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.safeAreaBar(edge: .bottom, spacing: 0) { footer }
        } else {
            content.safeAreaInset(edge: .bottom, spacing: 0) {
                footer.background(.bar)
            }
        }
    }
}

private extension View {
    func workspaceSection() -> some View {
        padding(14)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.primary.opacity(0.08))
                    .allowsHitTesting(false)
            }
    }
}

private enum SidebarLayout {
    static let minWidth: CGFloat = 380
    static let idealWidth: CGFloat = 460
    static let maxWidth: CGFloat = 560
}

private struct MultiSelectOption<ID: Hashable>: Identifiable {
    let id: ID
    let title: String
}

private struct MultiSelectionMenu<ID: Hashable>: View {
    let selectionTitle: String
    let emptyTitle: String
    let options: [MultiSelectOption<ID>]
    let selectedIDs: Set<ID>
    let isDisabled: Bool
    let onClear: () -> Void
    let onToggle: (ID) -> Void

    var body: some View {
        Menu(selectionTitle) {
            Button(emptyTitle, action: onClear)
                .disabled(selectedIDs.isEmpty)

            if !options.isEmpty {
                Divider()
            }

            ForEach(options) { option in
                Toggle(option.title, isOn: Binding(
                    get: { selectedIDs.contains(option.id) },
                    set: { _ in onToggle(option.id) }
                ))
            }
        }
        .disabled(isDisabled)
    }
}

struct ContentView: View {
    @EnvironmentObject private var galleryStore: GalleryStore
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var promptModelStore: PromptModelStore
    @EnvironmentObject private var cameraProfileStore: CameraProfileStore
    @EnvironmentObject private var productReferenceStore: ProductReferenceStore
    @EnvironmentObject private var adAngleStore: AdAngleStore
    @EnvironmentObject private var promotionalContextStore: PromotionalContextStore
    @EnvironmentObject private var promptPresetStore: PromptPresetStore
    @State private var previewedImage: GalleryPreviewItem?
    @State private var previewedPrompt: GalleryPromptPreview?
    @State private var promptSearch = ""
    @State private var isTeamSignInPresented = false
    @State private var teamEmail = ""
    @State private var teamPassword = ""

    private let columns = [
        GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 16)
    ]

    var body: some View {
        NavigationSplitView {
            GeneratorSidebar()
                // Let the split view own the live divider position.
                .navigationSplitViewColumnWidth(
                    min: SidebarLayout.minWidth,
                    ideal: SidebarLayout.idealWidth,
                    max: SidebarLayout.maxWidth
                )
        } detail: {
            searchableGallery.navigationTitle("Gallery")
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                accountMenu
            }
        }
        .sheet(isPresented: $isTeamSignInPresented, onDismiss: { teamPassword = "" }) {
            teamSignIn
        }
        .task { await appModel.verifyTeamSession() }
        .sheet(isPresented: $appModel.isModelManagerPresented) {
            ModelManagerSheet()
                .environmentObject(promptModelStore)
        }
        .sheet(isPresented: $appModel.isCameraManagerPresented) {
            CameraManagerSheet()
                .environmentObject(cameraProfileStore)
        }
        .sheet(item: $previewedImage) { item in
            ImagePreviewSheet(item: item)
        }
        .sheet(item: $previewedPrompt) { item in
            GalleryPromptSheet(item: item)
        }
    }

    @ViewBuilder
    private var searchableGallery: some View {
        if #available(macOS 26.0, *) {
            detail.searchable(text: $promptSearch, placement: .toolbar, prompt: "Search prompts")
        } else {
            detail.searchable(text: $promptSearch, prompt: "Search prompts")
        }
    }

    private var accountMenu: some View {
        Menu {
            if let session = appModel.teamSession {
                Text(session.member.name)
                if appModel.teamSessionNeedsSignIn || session.isExpired {
                    Button("Log in again") { isTeamSignInPresented = true }
                } else {
                    let budget = Double(session.monthlyLimitCents) / 100
                    Text("\(budget, format: .currency(code: "USD")) monthly OpenAI limit")
                }
                Divider()
                Button("Log out") { Task { await appModel.signOutOfTeam() } }
            } else {
                Button("Log in with Soundbrenner") { isTeamSignInPresented = true }
            }
            if let message = appModel.teamAccessMessage {
                Text(message)
            }
        } label: {
            Label("Soundbrenner account", systemImage: "person.crop.circle")
        }
        .help("Soundbrenner account")
        .disabled(appModel.isChangingTeamSession || appModel.isGenerating)
    }

    private var teamSignIn: some View {
        VStack(spacing: 20) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().interpolation(.high)
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            Text("Log in to Mediaforge").font(.title.weight(.semibold))
            Form {
                TextField("", text: $teamEmail, prompt: Text("Soundbrenner email"))
                    .accessibilityLabel("Soundbrenner email")
                    .textContentType(.username)
                SecureField("", text: $teamPassword, prompt: Text("Password"))
                    .accessibilityLabel("Password")
                    .textContentType(.password)
            }
            .labelsHidden()
            .multilineTextAlignment(.leading)
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)

            if let message = appModel.teamAccessMessage {
                Text(message).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
            }

            Button(action: logInToTeam) {
                HStack(spacing: 8) {
                    if appModel.isChangingTeamSession { ProgressView().controlSize(.small) }
                    Text(appModel.isChangingTeamSession ? "Logging in…" : "Log in")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(MediaforgeActionStyle(prominent: true))
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(teamEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || teamPassword.isEmpty)
            .padding(.horizontal, 20)

            Button("Cancel") { teamPassword = ""; isTeamSignInPresented = false }
                .buttonStyle(.link)
                .keyboardShortcut(.cancelAction)
        }
        .disabled(appModel.isChangingTeamSession)
        .interactiveDismissDisabled(appModel.isChangingTeamSession)
        .frame(width: 360)
        .padding(24)
    }

    private func logInToTeam() {
        let password = teamPassword
        teamPassword = ""
        Task {
            await appModel.signInToTeam(email: teamEmail, password: password)
            if appModel.teamAccessMessage == nil { isTeamSignInPresented = false }
        }
    }
}

private struct GeneratorSidebar: View {
    private struct ShotModeSelectionSnapshot {
        var selectedModelIDs: [UUID]
        var randomModelMode: RandomModelMode
        var selectedProductID: String?
        var selectedAdAngleIDs: [String]
        var useRandomAdAngle: Bool
        var selectedPromotionalContextIDs: [String]
        var useRandomPromotionalContext: Bool
        var selectedPresetIDs: [PromptPresetCategory: [String]]
        var randomPresetCategories: Set<PromptPresetCategory>

        static let empty = ShotModeSelectionSnapshot(
            selectedModelIDs: [],
            randomModelMode: .none,
            selectedProductID: nil,
            selectedAdAngleIDs: [],
            useRandomAdAngle: false,
            selectedPromotionalContextIDs: [],
            useRandomPromotionalContext: false,
            selectedPresetIDs: [:],
            randomPresetCategories: []
        )
    }

    @EnvironmentObject private var galleryStore: GalleryStore
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var promptModelStore: PromptModelStore
    @EnvironmentObject private var cameraProfileStore: CameraProfileStore
    @EnvironmentObject private var productReferenceStore: ProductReferenceStore
    @EnvironmentObject private var adAngleStore: AdAngleStore
    @EnvironmentObject private var promotionalContextStore: PromotionalContextStore
    @EnvironmentObject private var promptPresetStore: PromptPresetStore

    @State private var formDraft = GenerationForm()
    @State private var apiKeyDraft = ""
    @State private var geminiAPIKeyDraft = ""
    @AppStorage("generator_connection_settings_expanded") private var showsConnections = false
    @AppStorage("generator_output_settings_expanded") private var showsOutputSettings = true
    @State private var hasLoadedDraft = false
    @State private var draftPersistenceTask: Task<Void, Never>?
    @State private var previewedReferenceImage: GalleryPreviewItem?
    @State private var sharedProfileFolderStatus = SharedProfileStorage.statusText()
    @State private var shotModeSelections: [ShotMode: ShotModeSelectionSnapshot] = [:]
    @State private var isApplyingCopiedSetup = false

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                generationControls
            }
            .padding(20)
        }
        .modifier(GeneratorFooterPlacement(footer: generationFooter))
        .onAppear {
            // Stores restore their startup caches during initialization. Reloading
            // cloud-backed libraries here blocks the first window and defeats them.
            guard !hasLoadedDraft else {
                return
            }
            formDraft = appModel.form
            apiKeyDraft = appModel.apiKey
            geminiAPIKeyDraft = appModel.geminiAPIKey
            shotModeSelections[appModel.form.shotMode] = currentShotModeSelection()
            hasLoadedDraft = true
        }
        .onChange(of: formDraft) { _, newValue in
            guard hasLoadedDraft else {
                return
            }
            scheduleDraftPersistence(newValue)
        }
        .onChange(of: formDraft.shotMode) { oldValue, newValue in
            guard !isApplyingCopiedSetup else {
                return
            }
            shotModeSelections[oldValue] = currentShotModeSelection()
            restoreShotModeSelection(for: newValue)
        }
        .onChange(of: formDraft.audience) { _, newValue in
            guard !isApplyingCopiedSetup else {
                return
            }
            if appModel.randomModelMode.audienceKind != nil {
                appModel.selectRandomModelMode(newValue.randomModelMode)
            }
            appModel.selectedModelIDs = appModel.selectedModelIDs.filter { id in
                promptModelStore.profile(with: id).map(newValue.includes) ?? false
            }
        }
        .onChange(of: appModel.setupRevision) { _, _ in
            isApplyingCopiedSetup = true
            formDraft = appModel.form
            shotModeSelections[appModel.form.shotMode] = currentShotModeSelection()
            DispatchQueue.main.async {
                isApplyingCopiedSetup = false
            }
        }
        .sheet(item: $previewedReferenceImage) { item in
            ImagePreviewSheet(item: item)
        }
    }

    var body: some View {
        sidebar.tint(.mediaforgeAccent)
    }

    @ViewBuilder
    private var generationControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Prompt")
                .font(.headline)

            TextEditor(text: $formDraft.prompt)
                .font(.body)
                .frame(height: 182)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.primary.opacity(0.12))
                        .allowsHitTesting(false)
                }
                .accessibilityLabel("Prompt")
                .accessibilityHint("Describe the image you want to create.")
        }

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Reference photos")
                    .font(.headline)
                Spacer()
                Button {
                    appModel.addReferenceImages()
                } label: {
                    Label("Add photos", systemImage: "plus")
                }
                .buttonStyle(MediaforgeActionStyle())
            }

            ForEach(appModel.referenceImageURLs, id: \.self) { url in
                ReferencePhotoRow(
                    fileURL: url,
                    title: url.lastPathComponent,
                    openAction: {
                        previewedReferenceImage = ImagePreviewFactory.item(for: url)
                    },
                    removeAction: {
                        appModel.removeReferenceImage(url)
                    }
                )
            }
        }

        shotModeSelector

        if formDraft.shotMode.usesAudienceSelection {
            audienceSelector
        }

        if formDraft.shotMode != .plain {
            layeredPresetSelectors
        }

        DisclosureGroup("Output settings", isExpanded: $showsOutputSettings) {
            VStack(alignment: .leading, spacing: 14) {
                imageModelSelector
                Picker("Quality", selection: $formDraft.quality) {
                    ForEach(ImageQuality.supported(by: formDraft.imageModel)) { quality in
                        Text(quality.title).tag(quality)
                    }
                }
                .disabled(formDraft.imageModel.isGeminiImageModel)

                if formDraft.imageModel.isGeminiImageModel {
                    Picker("Aspect ratio", selection: $formDraft.geminiAspectRatio) {
                        ForEach(GeminiAspectRatio.allCases) { aspectRatio in
                            Text(aspectRatio.title).tag(aspectRatio)
                        }
                    }

                    Picker("Resolution", selection: $formDraft.geminiImageSize) {
                        ForEach(GeminiImageSize.allCases) { imageSize in
                            Text(imageSize.title).tag(imageSize)
                        }
                    }
                    .help("Nano Banana Pro costs about $0.134 per 1K or 2K image and $0.24 per 4K image.")
                } else {
                    Picker("Resolution", selection: $formDraft.resolution) {
                        ForEach(ResolutionPreset.allCases) { preset in
                            Text("\(preset.title) • \(preset.subtitle)")
                                .tag(preset)
                        }
                    }
                }

                Stepper(value: $formDraft.imageCount, in: 1...8) {
                    HStack {
                        Text("Images")
                        Spacer()
                        Text("\(formDraft.imageCount)")
                            .foregroundStyle(.secondary)
                    }
                }

                Picker("Format", selection: $formDraft.outputFormat) {
                    ForEach(OutputFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }
                .disabled(formDraft.imageModel.isGeminiImageModel)

                if formDraft.outputFormat != .png {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Compression")
                            Spacer()
                            Text("\(formDraft.outputCompression)%")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(
                            get: { Double(formDraft.outputCompression) },
                            set: { formDraft.outputCompression = Int($0.rounded()) }
                        ), in: 0...100, step: 1)
                    }
                }

                Picker("Moderation", selection: $formDraft.moderation) {
                    ForEach(ModerationLevel.allCases) { level in
                        Text(level.title).tag(level)
                    }
                }
                .disabled(formDraft.imageModel.isGeminiImageModel)
            }
            .padding(.top, 10)
        }
        .workspaceSection()

        DisclosureGroup("Connections", isExpanded: $showsConnections) {
            VStack(alignment: .leading, spacing: 15) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Shared JSON folder")
                        .font(.headline)

                    Text(sharedProfileFolderStatus)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button("Choose Dropbox folder") {
                        chooseSharedProfileFolder()
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Personal API keys")
                        .font(.headline)

                    Text("OpenAI")
                        .font(.subheadline.weight(.semibold))
                    SecureField("sk-...", text: $apiKeyDraft)
                        .textFieldStyle(.roundedBorder)

                    Button("Save OpenAI key securely") {
                        appModel.apiKey = apiKeyDraft
                        appModel.saveAPIKey()
                    }

                    Divider()

                    Text("Gemini · Nano Banana Pro")
                        .font(.subheadline.weight(.semibold))
                    SecureField("Gemini API key", text: $geminiAPIKeyDraft)
                        .textFieldStyle(.roundedBorder)

                    Button("Save Gemini key securely") {
                        appModel.geminiAPIKey = geminiAPIKeyDraft
                        appModel.saveGeminiAPIKey()
                    }
                }
            }
            .padding(.top, 10)
        }
        .workspaceSection()
    }

    private var generationFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: startGeneration) {
                Label("Generate images", systemImage: "sparkles")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(MediaforgeActionStyle(prominent: true))
            .controlSize(.large)
            .disabled(galleryStore.historyError != nil)

            if let error = appModel.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            } else if !appModel.statusMessage.isEmpty {
                Text(appModel.statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 14)
    }

    private func startGeneration() {
        appModel.apiKey = apiKeyDraft
        appModel.geminiAPIKey = geminiAPIKeyDraft
        appModel.generate(
            form: formDraft,
            using: galleryStore,
            modelStore: promptModelStore,
            cameraStore: cameraProfileStore,
            productStore: productReferenceStore,
            adAngleStore: adAngleStore,
            promotionalContextStore: promotionalContextStore,
            presetStore: promptPresetStore
        )
    }

    private func currentShotModeSelection() -> ShotModeSelectionSnapshot {
        ShotModeSelectionSnapshot(
            selectedModelIDs: appModel.selectedModelIDs,
            randomModelMode: appModel.randomModelMode,
            selectedProductID: appModel.selectedProductID,
            selectedAdAngleIDs: appModel.selectedAdAngleIDs,
            useRandomAdAngle: appModel.useRandomAdAngle,
            selectedPromotionalContextIDs: appModel.selectedPromotionalContextIDs,
            useRandomPromotionalContext: false,
            selectedPresetIDs: appModel.selectedPresetIDs,
            randomPresetCategories: appModel.randomPresetCategories
        )
    }

    private func restoreShotModeSelection(for shotMode: ShotMode) {
        guard let snapshot = shotModeSelections[shotMode] else {
            normalizeCurrentSelection(for: shotMode)
            return
        }

        if shotMode.allowsModelSelection {
            appModel.randomModelMode = snapshot.randomModelMode
            appModel.selectedModelIDs = snapshot.randomModelMode == .none ? snapshot.selectedModelIDs : []
        } else {
            appModel.randomModelMode = .none
            appModel.selectedModelIDs = []
        }

        if let productID = snapshot.selectedProductID,
           productReferenceStore.product(with: productID)?.applies(to: shotMode) == true {
            appModel.selectedProductID = productID
        } else {
            appModel.selectedProductID = nil
        }

        appModel.useRandomAdAngle = snapshot.useRandomAdAngle
        appModel.selectedAdAngleIDs = snapshot.useRandomAdAngle ? [] : snapshot.selectedAdAngleIDs
        appModel.useRandomPromotionalContext = false
        appModel.selectedPromotionalContextIDs = Array(snapshot.selectedPromotionalContextIDs.prefix(1))
        appModel.randomPresetCategories = snapshot.randomPresetCategories.filter { $0.applies(to: shotMode) }
        appModel.selectedPresetIDs = snapshot.selectedPresetIDs.compactMapValues { presetIDs in
            let filteredIDs = presetIDs.filter { presetID in
                guard let preset = promptPresetStore.profile(with: presetID) else {
                    return false
                }

                return preset.applies(to: formDraft.audience, in: shotMode)
            }

            return filteredIDs.isEmpty ? nil : filteredIDs
        }.filter { category, _ in
            guard category.applies(to: shotMode) else {
                return false
            }
            return true
        }
    }

    private func normalizeCurrentSelection(for shotMode: ShotMode) {
        if shotMode.allowsModelSelection {
            appModel.selectedModelIDs = appModel.selectedModelIDs.filter { id in
                promptModelStore.profile(with: id).map(formDraft.audience.includes) ?? false
            }
        } else {
            appModel.randomModelMode = .none
            appModel.selectedModelIDs = []
        }

        if let productID = appModel.selectedProductID,
           productReferenceStore.product(with: productID)?.applies(to: shotMode) != true {
            appModel.selectedProductID = nil
        }

        appModel.randomPresetCategories = appModel.randomPresetCategories.filter { $0.applies(to: shotMode) }
        appModel.selectedPresetIDs = appModel.selectedPresetIDs.compactMapValues { presetIDs in
            let filteredIDs = presetIDs.filter { presetID in
                guard let preset = promptPresetStore.profile(with: presetID) else {
                    return false
                }

                return preset.applies(to: formDraft.audience, in: shotMode)
            }

            return filteredIDs.isEmpty ? nil : filteredIDs
        }.filter { category, _ in
            guard category.applies(to: shotMode) else {
                return false
            }
            return true
        }

        shotModeSelections[shotMode] = currentShotModeSelection()
    }

    private var imageModelSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Image model")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("Refresh") {
                    appModel.apiKey = apiKeyDraft
                    Task {
                        await appModel.refreshAvailableImageModels()
                        formDraft.imageModel = appModel.form.imageModel
                    }
                }
            }

            Picker("Image model", selection: $formDraft.imageModel) {
                ForEach(appModel.availableImageModels) { model in
                    Text(model.title).tag(model.id)
                }
            }
            .labelsHidden()
            .help(ImageModelOption(id: formDraft.imageModel).guidance)
            .onChange(of: formDraft.imageModel) { _, newModel in
                if !ImageQuality.supported(by: newModel).contains(formDraft.quality) {
                    formDraft.quality = .high
                }
                if newModel.isGeminiImageModel {
                    formDraft.outputFormat = .png
                }
            }
        }
    }

    private var shotModeSelector: some View {
        let picker = Picker("Shot mode", selection: $formDraft.shotMode) {
            ForEach(ShotMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        return VStack(alignment: .leading, spacing: 10) {
            Text("Shot mode")
                .font(.headline)

            ViewThatFits(in: .horizontal) {
                picker.pickerStyle(.segmented)
                picker.pickerStyle(.menu)
            }
            .labelsHidden()
            .help(formDraft.shotMode.subtitle)
            .accessibilityHint(formDraft.shotMode.subtitle)
        }
    }

    private var audienceSelector: some View {
        let picker = Picker("Audience", selection: $formDraft.audience) {
            ForEach(AudienceKind.allCases) { audience in
                Text(audience.title).tag(audience)
            }
        }
        return VStack(alignment: .leading, spacing: 10) {
            Text("Audience")
                .font(.headline)

            ViewThatFits(in: .horizontal) {
                picker.pickerStyle(.segmented)
                picker.pickerStyle(.menu)
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Color.mediaforgeAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.mediaforgeAccent.opacity(0.22), lineWidth: 1)
        }
    }

    private var productSelector: some View {
        let products = productReferenceStore.products.filter { $0.applies(to: formDraft.shotMode) }

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Product")
                    .font(.headline)
            }

            Picker("Product", selection: Binding(
                get: { appModel.selectedProductID ?? "" },
                set: { appModel.selectProduct($0.isEmpty ? nil : $0) }
            )) {
                Text("No product").tag("")
                ForEach(products) { product in
                    Text(product.name).tag(product.id)
                }
            }
            .labelsHidden()

            if let product = productReferenceStore.product(with: appModel.selectedProductID),
               product.applies(to: formDraft.shotMode) {
                productReferenceSummary(product)
            } else if productReferenceStore.products.isEmpty {
                Text("No product folders found in Dropbox image generation/products.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if products.isEmpty {
                Text("No product references for \(formDraft.shotMode.title.lowercased()).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }

    private var adAngleSelector: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Ad angle")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("Clear") {
                    appModel.selectRandomAdAngle(false)
                    appModel.selectedAdAngleIDs = []
                }
                .buttonStyle(.borderless)
                .disabled(!appModel.useRandomAdAngle && appModel.selectedAdAngleIDs.isEmpty)
                Toggle("Random", isOn: Binding(
                    get: { appModel.useRandomAdAngle },
                    set: { appModel.selectRandomAdAngle($0) }
                ))
                .toggleStyle(.switch)
            }

            MultiSelectionMenu(
                selectionTitle: selectionSummary(
                    selectedNames: appModel.selectedAdAngleIDs.compactMap { id in
                        adAngleStore.adAngle(with: id)?.name
                    },
                    emptyTitle: "No ad angle"
                ),
                emptyTitle: "No ad angle",
                options: adAngleStore.adAngles.map {
                    MultiSelectOption(id: $0.id, title: $0.name)
                },
                selectedIDs: Set(appModel.selectedAdAngleIDs),
                isDisabled: appModel.useRandomAdAngle,
                onClear: {
                    appModel.selectRandomAdAngle(false)
                    appModel.selectedAdAngleIDs = []
                },
                onToggle: appModel.toggleAdAngleSelection
            )

            if appModel.useRandomAdAngle {
                Text("Random ad angle will be picked per image.")
                    .font(.footnote)
                    .foregroundStyle(Color.mediaforgeAccent)
            } else if appModel.selectedAdAngleIDs.count == 1,
                      let adAngle = adAngleStore.adAngle(with: appModel.selectedAdAngleID) {
                adAngleSummary(adAngle)
            } else if appModel.selectedAdAngleIDs.count > 1 {
                Text("\(appModel.selectedAdAngleIDs.count) ad angles selected. One will be used per generated image.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if adAngleStore.adAngles.isEmpty {
                Text("No ad-angle folders found in Dropbox image generation/ad angles.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var promotionalContextSelector: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Promotional context")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("Clear") {
                    appModel.selectPromotionalContext(nil)
                }
                .buttonStyle(.borderless)
                .disabled(appModel.selectedPromotionalContextIDs.isEmpty)
            }

            Picker("Promotional context", selection: Binding(
                get: { appModel.selectedPromotionalContextID ?? "" },
                set: { appModel.selectPromotionalContext($0.isEmpty ? nil : $0) }
            )) {
                Text("No promotional context").tag("")
                ForEach(promotionalContextStore.promotionalContexts) { context in
                    Text(context.name).tag(context.id)
                }
            }
            .labelsHidden()

            if let context = promotionalContextStore.promotionalContext(with: appModel.selectedPromotionalContextID) {
                promotionalContextSummary(context)
            } else if promotionalContextStore.promotionalContexts.isEmpty {
                Text("No promotional-context folders found in Dropbox image generation/promotional contexts.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var layeredPresetSelectors: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Creative layers")
                    .font(.headline)
                Spacer()
                Button("Clear all") {
                    appModel.clearCreativeLayers()
                }
                .disabled(!hasCreativeLayerSelection)
                Button("Refresh") {
                    refreshJSONLibraries()
                }
            }

            productSelector

            adAngleSelector

            promotionalContextSelector

            if formDraft.shotMode.usesAudienceSelection {
                audienceDependentLayerGroup
            }

            presetSelector(for: .composition)
            presetSelector(for: .look)
        }
    }

    private var hasCreativeLayerSelection: Bool {
        appModel.randomModelMode != .none
            || !appModel.selectedModelIDs.isEmpty
            || appModel.useRandomAdAngle
            || !appModel.selectedAdAngleIDs.isEmpty
            || !appModel.selectedPromotionalContextIDs.isEmpty
            || !appModel.randomPresetCategories.isEmpty
            || appModel.selectedPresetIDs.values.contains { !$0.isEmpty }
    }

    private func refreshJSONLibraries() {
        promptModelStore.reloadStorageLocation()
        cameraProfileStore.reloadStorageLocation()
        productReferenceStore.reload()
        adAngleStore.reload()
        promotionalContextStore.reload()
        promptPresetStore.reload()
        sharedProfileFolderStatus = SharedProfileStorage.statusText()
        appModel.statusMessage = "Products and creative libraries refreshed."
        appModel.lastError = nil
    }

    private func selectionSummary(selectedNames: [String], emptyTitle: String) -> String {
        let uniqueNames = Array(NSOrderedSet(array: selectedNames).array.compactMap { $0 as? String })
        guard let firstName = uniqueNames.first else {
            return emptyTitle
        }

        if uniqueNames.count == 1 {
            return firstName
        }

        return "\(firstName) + \(uniqueNames.count - 1)"
    }

    private var modelLayerSelector: some View {
        let profiles = promptModelStore.profiles.filter(formDraft.audience.includes)
        let isRandomModel = appModel.randomModelMode == formDraft.audience.randomModelMode

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Models")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("Clear") {
                    appModel.selectRandomModelMode(.none)
                    appModel.selectModels([])
                }
                .buttonStyle(.borderless)
                .disabled(appModel.randomModelMode == .none && appModel.selectedModelIDs.isEmpty)
                Toggle("Random", isOn: Binding(
                    get: { isRandomModel },
                    set: { isEnabled in
                        appModel.selectRandomModelMode(isEnabled ? formDraft.audience.randomModelMode : .none)
                    }
                ))
                .toggleStyle(.switch)
            }

            MultiSelectionMenu(
                selectionTitle: selectionSummary(
                    selectedNames: appModel.selectedModelIDs.compactMap { id in
                        promptModelStore.profile(with: id)?.name
                    },
                    emptyTitle: "No model"
                ),
                emptyTitle: "No model",
                options: profiles.map {
                    MultiSelectOption(id: $0.id, title: $0.name)
                },
                selectedIDs: Set(appModel.selectedModelIDs),
                isDisabled: isRandomModel,
                onClear: {
                    appModel.selectRandomModelMode(.none)
                    appModel.selectModels([])
                },
                onToggle: appModel.toggleModelSelection
            )

            HStack {
                if appModel.randomModelMode != .none {
                    Text("\(appModel.randomModelMode.title) will be picked per image.")
                        .font(.caption)
                        .foregroundStyle(Color.mediaforgeAccent)
                } else if appModel.selectedModelIDs.count > 1 {
                    Text("\(appModel.selectedModelIDs.count) selected models. One will be used per generated image.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if profiles.isEmpty {
                    Text("No \(formDraft.audience.title.lowercased()) models found.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Manage") {
                    appModel.isModelManagerPresented = true
                }
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }

    private var audienceDependentLayerGroup: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(formDraft.audience.title) layers")
                .font(.subheadline.weight(.semibold))

            if formDraft.shotMode.allowsModelSelection {
                modelLayerSelector
            }

            presetSelector(for: .setting)
        }
        .padding(12)
        .background(Color.mediaforgeAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.mediaforgeAccent.opacity(0.28), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func presetSelector(for category: PromptPresetCategory) -> some View {
        if category.applies(to: formDraft.shotMode) {
            let profiles = promptPresetStore.profiles(
                for: category,
                shotMode: formDraft.shotMode,
                audience: category == .setting && formDraft.shotMode.usesAudienceSelection ? formDraft.audience : nil
            )
            let isRandom = appModel.randomPresetCategories.contains(category)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(category.title)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Toggle("Random", isOn: Binding(
                        get: { isRandom },
                        set: { _ in appModel.toggleRandomPreset(for: category) }
                    ))
                    .toggleStyle(.switch)
                }

                MultiSelectionMenu(
                    selectionTitle: selectionSummary(
                        selectedNames: appModel.selectedPresetIDs[category, default: []].compactMap { id in
                            promptPresetStore.profile(with: id)?.name
                        },
                        emptyTitle: "No \(category.title.lowercased())"
                    ),
                    emptyTitle: "No \(category.title.lowercased())",
                    options: profiles.map {
                        MultiSelectOption(id: $0.id, title: $0.name)
                    },
                    selectedIDs: Set(appModel.selectedPresetIDs[category, default: []]),
                    isDisabled: isRandom,
                    onClear: {
                        appModel.selectPreset(nil, for: category)
                    },
                    onToggle: { id in
                        appModel.togglePresetSelection(id, for: category)
                    }
                )

                if isRandom {
                    Text("\(category.randomTitle) will be picked per image.")
                        .font(.caption)
                        .foregroundStyle(Color.mediaforgeAccent)
                } else if appModel.selectedPresetIDs[category, default: []].count > 1 {
                    Text("\(appModel.selectedPresetIDs[category, default: []].count) \(category.title.lowercased()) options selected. One will be used per generated image.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if profiles.isEmpty {
                    Text("No \(category.title.lowercased()) presets found yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func productReferenceSummary(_ product: ProductReferenceProfile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(product.referenceImageURLs.prefix(4), id: \.self) { url in
                    Button {
                        previewedReferenceImage = ImagePreviewFactory.item(
                            for: url,
                            displayName: url.lastPathComponent
                        )
                    } label: {
                        GalleryThumbnailImage(
                            fileURL: url,
                            cacheKey: "product-reference-\(url.path)",
                            maxPixelSize: 160
                        )
                        .frame(width: 42, height: 42)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.primary.opacity(0.08))
                        }
                    }
                    .buttonStyle(.plain)
                    .help(url.lastPathComponent)
                }
            }

            Text(product.name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func adAngleSummary(_ adAngle: AdAngleProfile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(adAngle.referenceImageURLs.prefix(4), id: \.self) { url in
                    Button {
                        previewedReferenceImage = ImagePreviewFactory.item(
                            for: url,
                            displayName: url.lastPathComponent
                        )
                    } label: {
                        GalleryThumbnailImage(
                            fileURL: url,
                            cacheKey: "ad-angle-reference-\(url.path)",
                            maxPixelSize: 160
                        )
                        .frame(width: 42, height: 42)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.primary.opacity(0.08))
                        }
                    }
                    .buttonStyle(.plain)
                    .help(url.lastPathComponent)
                }
            }

            Text("\(adAngle.referenceImageURLs.count) ad-angle reference image\(adAngle.referenceImageURLs.count == 1 ? "" : "s") + JSON")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func promotionalContextSummary(_ context: PromotionalContextProfile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !context.referenceImageURLs.isEmpty {
                HStack(spacing: 8) {
                    ForEach(context.referenceImageURLs.prefix(4), id: \.self) { url in
                        Button {
                            previewedReferenceImage = ImagePreviewFactory.item(
                                for: url,
                                displayName: url.lastPathComponent
                            )
                        } label: {
                            GalleryThumbnailImage(
                                fileURL: url,
                                cacheKey: "promotional-context-reference-\(url.path)",
                                maxPixelSize: 160
                            )
                            .frame(width: 42, height: 42)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.primary.opacity(0.08))
                            }
                        }
                        .buttonStyle(.plain)
                        .help(url.lastPathComponent)
                    }
                }
            }

            Text(context.referenceImageURLs.isEmpty ? "JSON only" : "\(context.referenceImageURLs.count) reference image\(context.referenceImageURLs.count == 1 ? "" : "s") + JSON")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var selectedModelCard: some View {
        let isDisabledByStyle = selectedStyleDisablesModels

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Selected model")
                    .font(.headline)
                Spacer()
                Button("Manage") {
                    appModel.isModelManagerPresented = true
                }
                .disabled(isDisabledByStyle)
            }

            if isDisabledByStyle {
                Text(formDraft.shotMode.allowsModelSelection ? "Disabled by selected in-context style. Model JSON will not be sent." : "Disabled by shot mode. Model JSON will not be sent.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if promptModelStore.profiles.isEmpty {
                Text("No saved models yet. Add one with a thumbnail and JSON metadata.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if appModel.randomModelMode != .none {
                Button {
                    appModel.selectRandomModelMode(.none)
                } label: {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.mediaforgeAccent.opacity(0.14))
                            .frame(width: 40, height: 40)
                            .overlay {
                                Image(systemName: "shuffle")
                                    .foregroundStyle(Color.mediaforgeAccent)
                            }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(appModel.randomModelMode.title)
                                .foregroundStyle(.primary)
                            Text("\(appModel.randomModelMode.subtitle) One model is picked per generated image.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        Spacer()
                    }
                    .padding(10)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)

                Text("Click random model to clear it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                let selectedProfiles = appModel.selectedModelIDs.compactMap(promptModelStore.profile(with:))

                if selectedProfiles.isEmpty {
                    Text("No model selected.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(selectedProfiles) { profile in
                            selectedModelRow(profile)
                        }

                        Text("Click a selected model to remove it.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var selectedStyleDisablesModels: Bool {
        !formDraft.shotMode.allowsModelSelection
    }

    private func selectedModelRow(_ profile: PromptModelProfile) -> some View {
        Button {
            appModel.toggleModelSelection(profile.id)
        } label: {
            HStack(spacing: 10) {
                if let image = promptModelStore.thumbnailImage(for: profile) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.12))
                        .frame(width: 40, height: 40)
                        .overlay {
                            Image(systemName: "person.crop.square")
                                .foregroundStyle(.secondary)
                        }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name)
                        .foregroundStyle(.primary)
                    Text(profile.normalizedPromptJSON)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()
            }
            .padding(10)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private var selectedCameraCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Selected style")
                    .font(.headline)
                Spacer()
                Button("Manage") {
                    appModel.isCameraManagerPresented = true
                }
            }

            if cameraProfileStore.profiles.isEmpty {
                Text("No saved styles yet. Add one with a style JSON.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if let selectedID = appModel.selectedCameraID,
                      let profile = cameraProfileStore.profile(with: selectedID) {
                Button {
                    appModel.selectCamera(nil)
                } label: {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.secondary.opacity(0.12))
                            .frame(width: 40, height: 40)
                            .overlay {
                                Image(systemName: "wand.and.stars")
                                    .foregroundStyle(.secondary)
                            }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.name)
                                .foregroundStyle(.primary)
                            Text(profile.audienceLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text(profile.normalizedPromptJSON)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        Spacer()
                    }
                    .padding(10)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)

                Text("Click the selected style to clear it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if !formDraft.cameraJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Using legacy inline style JSON.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("No style selected.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func scheduleDraftPersistence(_ draft: GenerationForm) {
        draftPersistenceTask?.cancel()
        draftPersistenceTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else {
                return
            }
            await MainActor.run {
                appModel.persistDraftForm(draft)
            }
        }
    }

    private func chooseSharedProfileFolder() {
        do {
            try SharedProfileStorage.authorizeSharedFolder()
            promptModelStore.reloadStorageLocation()
            cameraProfileStore.reloadStorageLocation()
            productReferenceStore.reload()
            adAngleStore.reload()
            promotionalContextStore.reload()
            promptPresetStore.reload()
            sharedProfileFolderStatus = SharedProfileStorage.statusText()
            appModel.statusMessage = "Shared JSON folder connected."
            appModel.lastError = nil
        } catch {
            appModel.lastError = error.localizedDescription
        }
    }
}

private extension ContentView {
    private var matchingJobs: [GenerationJob] {
        galleryStore.jobs.filter { PromptSearch.matches($0.inputPrompt, query: promptSearch) }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = galleryStore.historyError {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle")
                    Spacer()
                    Button("Retry loading") { galleryStore.loadHistory() }
                }
                .padding(16)
                .background(.bar)
            }

            if !appModel.pendingGenerations.isEmpty || !galleryStore.jobs.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        if !promptSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("\(matchingJobs.count) matches")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        if !appModel.pendingGenerations.isEmpty {
                            pendingGenerationsSection
                        }

                        if matchingJobs.isEmpty && !promptSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            ContentUnavailableView("No matching prompts", systemImage: "magnifyingglass", description: Text("Try different words or clear the search."))
                        }
                        ForEach(matchingJobs) { job in
                            VStack(alignment: .leading, spacing: 12) {
                                header(for: job)

                                if job.isFailed {
                                    failedGenerationCard(for: job)
                                } else {
                                    LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                                        ForEach(job.images) { image in
                                            imageCard(image, in: job)
                                        }
                                    }
                                }
                            }
                            .workspaceSection()
                        }
                    }
                    .padding(20)
                }
            } else if galleryStore.historyError == nil {
                ContentUnavailableView(
                    "No images yet",
                    systemImage: "photo.on.rectangle.angled",
                    description: Text("Generate your first batch and it will appear here.")
                )
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await appModel.refreshAvailableImageModels()
        }
    }

    private var pendingGenerationsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Generating")
                .font(.title3.weight(.semibold))

            ForEach(appModel.pendingGenerations) { pending in
                VStack(alignment: .leading, spacing: 8) {
                    pendingHeader(for: pending)

                    LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                        ForEach(0..<pending.imageCount, id: \.self) { index in
                            pendingImageCard(index: index, total: pending.imageCount)
                        }
                    }
                }
                .padding(18)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 20))
            }
        }
    }

    private func pendingHeader(for pending: PendingGenerationBatch) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(GalleryPromptTitle.text(for: pending.prompt))
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)

                    Text(pending.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .foregroundStyle(.secondary)

                    if !pending.modelSnapshots.isEmpty {
                        modelSummary(for: pending)
                            .padding(.top, 2)
                    }

                    setupSummary(for: pending)
                        .padding(.top, 2)

                    if let productSnapshot = pending.productSnapshot {
                        HStack(spacing: 8) {
                            productThumbnail(for: pending)

                            Text(productSnapshot.name)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 2)
                    }

                    if let adAngleSnapshot = pending.adAngleSnapshot {
                        HStack(spacing: 8) {
                            Image(systemName: pending.randomAdAngle ? "shuffle" : "rectangle.on.rectangle")
                                .foregroundStyle(Color.mediaforgeAccent)

                            Text(pending.randomAdAngle ? "Random ad angle: \(adAngleSnapshot.name)" : "Ad angle: \(adAngleSnapshot.name)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 2)
                    }

                    if !pending.promotionalContextSnapshots.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: pending.randomPromotionalContext ? "shuffle" : "tag")
                                .foregroundStyle(Color.mediaforgeAccent)

                            Text(pending.randomPromotionalContext ? "Random promotional context: \(setupNames(pending.promotionalContextSnapshots))" : "Promotional context: \(setupNames(pending.promotionalContextSnapshots))")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 2)
                    }

                    if !pending.referenceImages.isEmpty {
                        referencePhotoStrip(for: pending)
                            .padding(.top, 4)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 8) {
                    pendingActionButtons(for: pending)

                    metadataPill(pending.statusMessage)

                    TimelineView(.periodic(from: pending.createdAt, by: 1)) { context in
                        Text("Elapsed \(elapsedTimeText(from: pending.createdAt, to: context.date))")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Text(pending.detailMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .padding(.top, 4)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 2)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func pendingActionButtons(for pending: PendingGenerationBatch) -> some View {
        HStack(spacing: 8) {
            Button("Copy setup") { copySetup(from: pending) }
                .buttonStyle(MediaforgeActionStyle())
            Menu {
                Button("View prompt") {
                    previewedPrompt = GalleryPromptPreview(id: pending.id, text: pending.prompt)
                }
                Button("Copy prompt") { copyPrompt(for: pending) }
                Button("Copy prompt and JSON") { copyPromptWithJSONs(for: pending) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .help("Generation actions")
            .accessibilityLabel("Generation actions")
        }
    }

    private func elapsedTimeText(from startDate: Date, to endDate: Date) -> String {
        let seconds = max(0, Int(endDate.timeIntervalSince(startDate).rounded(.down)))
        if seconds < 60 {
            return "\(seconds)s"
        }

        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        return "\(minutes)m \(remainingSeconds)s"
    }

    private func header(for job: GenerationJob) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(GalleryPromptTitle.text(for: job.inputPrompt))
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)

                    Text(job.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .foregroundStyle(.secondary)

                    if !job.modelSnapshots.isEmpty {
                        modelSummary(for: job)
                            .padding(.top, 2)
                    }

                    setupSummary(for: job)
                        .padding(.top, 2)

                    if let productSnapshot = job.productSnapshot {
                        HStack(spacing: 8) {
                            productThumbnail(for: job)

                            Text(productSnapshot.name)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 2)
                    }

                    if let adAngleSnapshot = job.adAngleSnapshot {
                        HStack(spacing: 8) {
                            Image(systemName: job.randomAdAngle ? "shuffle" : "rectangle.on.rectangle")
                                .foregroundStyle(Color.mediaforgeAccent)

                            Text(job.randomAdAngle ? "Random ad angle: \(adAngleSnapshot.name)" : "Ad angle: \(adAngleSnapshot.name)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 2)
                    }

                    if !job.promotionalContextSnapshots.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: job.randomPromotionalContext ? "shuffle" : "tag")
                                .foregroundStyle(Color.mediaforgeAccent)

                            Text(job.randomPromotionalContext ? "Random promotional context: \(setupNames(job.promotionalContextSnapshots))" : "Promotional context: \(setupNames(job.promotionalContextSnapshots))")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 2)
                    }

                    if !job.referenceImages.isEmpty {
                        referencePhotoStrip(for: job)
                            .padding(.top, 4)
                    }
                }

                Spacer()

                HStack(spacing: 8) {
                    if job.isFailed {
                        Button("Retry") { retry(job) }
                            .buttonStyle(MediaforgeActionStyle(prominent: true))
                    }

                    Button("Copy setup") { copySetup(from: job) }
                        .buttonStyle(MediaforgeActionStyle())

                    Menu {
                        Button("View prompt") {
                            previewedPrompt = GalleryPromptPreview(id: job.id, text: job.inputPrompt)
                        }
                        Button("Copy prompt") { copyPrompt(for: job) }
                        Button("Copy prompt and JSON") { copyPromptWithJSONs(for: job) }
                        if job.isFailed {
                            Divider()
                            Button("Delete", role: .destructive) { delete(job: job) }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .help("Generation actions")
                    .accessibilityLabel("Generation actions")
                }
            }

        }
    }

    private func modelSummary(for job: GenerationJob) -> some View {
        HStack(spacing: 8) {
            if let modelSnapshot = job.modelSnapshots.first,
               let image = promptModelStore.thumbnailImage(for: modelSnapshot) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.12))
                    .frame(width: 28, height: 28)
                    .overlay {
                        Image(systemName: "person.crop.square")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
            }

            Text(modelSummaryText(for: job.modelSnapshots))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func modelSummary(for pending: PendingGenerationBatch) -> some View {
        HStack(spacing: 8) {
            if let modelSnapshot = pending.modelSnapshots.first,
               let image = promptModelStore.thumbnailImage(for: modelSnapshot) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.12))
                    .frame(width: 28, height: 28)
                    .overlay {
                        Image(systemName: "person.crop.square")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
            }

            Text(modelSummaryText(for: pending.modelSnapshots))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func setupSummary(for job: GenerationJob) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.12))
                .frame(width: 28, height: 28)
                .overlay {
                    Image(systemName: "slider.horizontal.3")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            Text(setupSummaryText(for: job))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private func setupSummary(for pending: PendingGenerationBatch) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.12))
                .frame(width: 28, height: 28)
                .overlay {
                    Image(systemName: "slider.horizontal.3")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            Text(setupSummaryText(for: pending))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private func modelSummaryText(for snapshots: [GenerationModelSnapshot]) -> String {
        let names = Array(NSOrderedSet(array: snapshots.map(\.name)).array.compactMap { $0 as? String })
        if names.count <= 1 {
            return names.first ?? "No model"
        }
        return "\(names.count) models: \(names.prefix(4).joined(separator: ", "))\(names.count > 4 ? "..." : "")"
    }

    private func setupNames(_ snapshots: [GenerationPromotionalContextSnapshot]) -> String {
        let names = Array(NSOrderedSet(array: snapshots.map(\.name)).array.compactMap { $0 as? String })
        if names.count <= 1 {
            return names.first ?? "None"
        }
        return "\(names.count): \(names.prefix(4).joined(separator: ", "))\(names.count > 4 ? "..." : "")"
    }

    private func setupSummaryText(for job: GenerationJob) -> String {
        setupSummaryText(
            shotMode: job.shotMode,
            presetSnapshots: job.presetSnapshots,
            cameraSnapshot: job.cameraSnapshot
        )
    }

    private func setupSummaryText(for pending: PendingGenerationBatch) -> String {
        setupSummaryText(
            shotMode: pending.shotMode,
            presetSnapshots: pending.presetSnapshots,
            cameraSnapshot: pending.cameraSnapshot
        )
    }

    private func setupSummaryText(
        shotMode: ShotMode,
        presetSnapshots: [GenerationPresetSnapshot],
        cameraSnapshot: GenerationCameraSnapshot?
    ) -> String {
        let groupedPresets = Dictionary(grouping: presetSnapshots, by: \.category)
        let presetText = PromptPresetCategory.allCases.compactMap { category -> String? in
            guard let snapshots = groupedPresets[category], !snapshots.isEmpty else {
                return nil
            }

            let names = Array(NSOrderedSet(array: snapshots.map(\.name)).array.compactMap { $0 as? String })
            let wasRandom = names.count > 1
            let displayedNames = names.prefix(3).joined(separator: ", ")
            let overflow = names.count > 3 ? " +\(names.count - 3) more" : ""
            let value = "\(displayedNames)\(overflow)\(wasRandom ? " (random)" : "")"
            return "\(category.title): \(value)"
        }

        if !presetText.isEmpty {
            return "\(shotMode.title) • \(presetText.joined(separator: " • "))"
        }

        if let legacyStyle = cameraSnapshot?.name, !legacyStyle.isEmpty {
            return "\(shotMode.title) • Style: \(legacyStyle)"
        }

        return shotMode.title
    }

    @ViewBuilder
    private func productThumbnail(for job: GenerationJob) -> some View {
        if let referenceImage = job.referenceImages.first {
            let fileURL = appModel.referenceImageURL(for: referenceImage)
            Button {
                previewedImage = ImagePreviewFactory.item(
                    for: fileURL,
                    displayName: referenceImage.originalFileName
                )
            } label: {
                GalleryThumbnailImage(
                    fileURL: fileURL,
                    cacheKey: "product-\(referenceImage.fileName)"
                )
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.primary.opacity(0.08))
                }
            }
            .buttonStyle(.plain)
            .help("Open product reference photo")
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.12))
                .frame(width: 28, height: 28)
                .overlay {
                    Image(systemName: "shippingbox")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
        }
    }

    @ViewBuilder
    private func productThumbnail(for pending: PendingGenerationBatch) -> some View {
        if let referenceImage = pending.referenceImages.first {
            let fileURL = appModel.referenceImageURL(for: referenceImage)
            Button {
                previewedImage = ImagePreviewFactory.item(
                    for: fileURL,
                    displayName: referenceImage.originalFileName
                )
            } label: {
                GalleryThumbnailImage(
                    fileURL: fileURL,
                    cacheKey: "pending-product-\(referenceImage.fileName)"
                )
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.primary.opacity(0.08))
                }
            }
            .buttonStyle(.plain)
            .help("Open product reference photo")
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.12))
                .frame(width: 28, height: 28)
                .overlay {
                    Image(systemName: "shippingbox")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
        }
    }

    private func referencePhotoStrip(for job: GenerationJob) -> some View {
        referencePhotoStrip(referenceImages: job.referenceImages, cachePrefix: "reference")
    }

    private func referencePhotoStrip(for pending: PendingGenerationBatch) -> some View {
        referencePhotoStrip(referenceImages: pending.referenceImages, cachePrefix: "pending-reference")
    }

    private func referencePhotoStrip(referenceImages: [GenerationReferenceImageSnapshot], cachePrefix: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Reference photos")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(referenceImages, id: \.self) { referenceImage in
                        let fileURL = appModel.referenceImageURL(for: referenceImage)
                        Button {
                            previewedImage = ImagePreviewFactory.item(
                                for: fileURL,
                                displayName: referenceImage.originalFileName
                            )
                        } label: {
                            GalleryThumbnailImage(
                                fileURL: fileURL,
                                cacheKey: "\(cachePrefix)-\(referenceImage.fileName)"
                            )
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.primary.opacity(0.08))
                            }
                            .help(referenceImage.originalFileName)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func metadataPill(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.08), in: Capsule())
    }

    private func imageCard(_ image: GalleryImage, in job: GenerationJob) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                if let item = previewItem(for: image) {
                    previewedImage = item
                }
            } label: {
                GalleryThumbnailImage(
                    fileURL: galleryStore.imageURL(for: image),
                    cacheKey: image.fileName,
                    contentMode: .fit
                )
                .aspectRatio(1.6, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Preview image")

            HStack(spacing: 8) {
                Text(image.format.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(image.fileName)

                Spacer(minLength: 4)
                Button {
                    appModel.export(image: image, using: galleryStore)
                } label: {
                    Label("Export image", systemImage: "square.and.arrow.up")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(MediaforgeActionStyle())
                .help("Export image")

                Menu {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([galleryStore.imageURL(for: image)])
                    }
                    Divider()
                    Button("Delete image", role: .destructive) {
                        delete(image: image, from: job)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .help("Image actions")
                .accessibilityLabel("Image actions")
            }
        }
    }

    private func failedGenerationCard(for job: GenerationJob) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(Color.mediaforgeAccent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Generation failed")
                    .font(.subheadline.weight(.semibold))
                if let failureMessage = job.failureMessage {
                    Text(failureMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .help(failureMessage)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.mediaforgeAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func pendingImageCard(index: Int, total: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.secondary.opacity(0.08))
                .aspectRatio(1.6, contentMode: .fit)
                .overlay {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Generating image \(index + 1) of \(total)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

            Text("Waiting for API result")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
    }

    private func previewImage(for image: GalleryImage) -> NSImage? {
        galleryStore.cachedImage(for: image)
    }

    private func previewItem(for image: GalleryImage) -> GalleryPreviewItem? {
        ImagePreviewFactory.item(
            for: galleryStore.imageURL(for: image),
            displayName: image.fileName,
            fallbackImage: previewImage(for: image)
        )
    }

    private func pixelSize(for image: NSImage) -> CGSize? {
        if let representation = image.representations.first(where: {
            $0.pixelsWide > 0 && $0.pixelsHigh > 0
        }) {
            return CGSize(width: representation.pixelsWide, height: representation.pixelsHigh)
        }
        return nil
    }

    private func delete(image: GalleryImage, from job: GenerationJob) {
        do {
            try galleryStore.delete(image: image, from: job)
            appModel.statusMessage = "Deleted image."
            appModel.lastError = nil
        } catch {
            appModel.lastError = error.localizedDescription
        }
    }

    private func delete(job: GenerationJob) {
        do {
            try galleryStore.delete(job: job)
            appModel.statusMessage = "Deleted failed generation."
            appModel.lastError = nil
        } catch {
            appModel.lastError = error.localizedDescription
        }
    }

    private func retry(_ job: GenerationJob) {
        appModel.retry(job: job, using: galleryStore)
    }

    private func copyPrompt(for pending: PendingGenerationBatch) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(pending.prompt, forType: .string)
        appModel.statusMessage = "Copied prompt."
        appModel.lastError = nil
    }

    private func copyPrompt(for job: GenerationJob) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(job.inputPrompt, forType: .string)
        appModel.statusMessage = "Copied prompt."
        appModel.lastError = nil
    }

    private func copySetup(from pending: PendingGenerationBatch) {
        let shouldRestoreRandomModel = pending.randomModelMode != .none
        let matchedModelIDs = shouldRestoreRandomModel ? [] : pending.modelSnapshots.compactMap { snapshot in
            promptModelStore.profiles.first { $0.name == snapshot.name }?.id
        }

        let matchedProductID = pending.productSnapshot.flatMap { snapshot in
            productReferenceStore.products.first { $0.name == snapshot.name }?.id
        }
        let shouldRestoreRandomAdAngle = pending.randomAdAngle
        let matchedAdAngleID = shouldRestoreRandomAdAngle ? nil : pending.adAngleSnapshot.flatMap { snapshot in
            adAngleStore.adAngles.first { $0.name == snapshot.name }?.id
        }
        let shouldRestoreRandomPromotionalContext = pending.randomPromotionalContext
        let matchedPromotionalContextIDs = shouldRestoreRandomPromotionalContext ? [] : pending.promotionalContextSnapshots.compactMap { snapshot in
            promotionalContextStore.promotionalContexts.first { $0.name == snapshot.name }?.id
        }

        let randomPresetCategories = copySetupRandomPresetCategories(for: pending)
        let matchedPresetIDs = pending.presetSnapshots.reduce(into: [PromptPresetCategory: String]()) { result, snapshot in
            guard !randomPresetCategories.contains(snapshot.category) else {
                return
            }
            result[snapshot.category] = promptPresetStore.profiles.first {
                $0.category == snapshot.category && $0.name == snapshot.name
            }?.id
        }

        let restoredReferenceImages: [GenerationReferenceImageSnapshot]
        if !pending.userReferenceImages.isEmpty {
            restoredReferenceImages = pending.userReferenceImages
        } else {
            restoredReferenceImages = matchedProductID == nil
                && matchedAdAngleID == nil
                && matchedPromotionalContextIDs.isEmpty
                && !shouldRestoreRandomAdAngle
                && !shouldRestoreRandomPromotionalContext ? pending.referenceImages : []
        }

        appModel.applySetup(
            prompt: pending.prompt,
            modelIDs: matchedModelIDs,
            cameraID: nil,
            productID: matchedProductID,
            adAngleID: matchedAdAngleID,
            randomAdAngle: shouldRestoreRandomAdAngle,
            promotionalContextIDs: matchedPromotionalContextIDs,
            randomPromotionalContext: shouldRestoreRandomPromotionalContext,
            shotMode: pending.shotMode,
            audience: pending.audience,
            presetIDs: matchedPresetIDs,
            randomModelMode: shouldRestoreRandomModel ? pending.randomModelMode : .none,
            randomPresetCategories: Set(randomPresetCategories),
            referenceImageURLs: restoredReferenceImages.map(appModel.referenceImageURL(for:))
        )
        appModel.statusMessage = "Copied setup with \(restoredReferenceImages.count) manual reference photo\(restoredReferenceImages.count == 1 ? "" : "s")."
        appModel.lastError = nil
    }

    private func copySetup(from job: GenerationJob) {
        let shouldRestoreRandomModel = job.randomModelMode != .none
        let matchedModelIDs = shouldRestoreRandomModel ? [] : job.modelSnapshots.compactMap { snapshot in
            promptModelStore.profiles.first { $0.name == snapshot.name }?.id
        }

        let matchedProductID = job.productSnapshot.flatMap { snapshot in
            productReferenceStore.products.first { $0.name == snapshot.name }?.id
        }
        let shouldRestoreRandomAdAngle = job.randomAdAngle
        let matchedAdAngleID = shouldRestoreRandomAdAngle ? nil : job.adAngleSnapshot.flatMap { snapshot in
            adAngleStore.adAngles.first { $0.name == snapshot.name }?.id
        }
        let shouldRestoreRandomPromotionalContext = job.randomPromotionalContext
        let matchedPromotionalContextIDs = shouldRestoreRandomPromotionalContext ? [] : job.promotionalContextSnapshots.compactMap { snapshot in
            promotionalContextStore.promotionalContexts.first { $0.name == snapshot.name }?.id
        }

        let randomPresetCategories = copySetupRandomPresetCategories(for: job)
        let matchedPresetIDs = job.presetSnapshots.reduce(into: [PromptPresetCategory: String]()) { result, snapshot in
            guard !randomPresetCategories.contains(snapshot.category) else {
                return
            }
            result[snapshot.category] = promptPresetStore.profiles.first {
                $0.category == snapshot.category && $0.name == snapshot.name
            }?.id
        }

        let restoredReferenceImages: [GenerationReferenceImageSnapshot]
        if !job.userReferenceImages.isEmpty {
            restoredReferenceImages = job.userReferenceImages
        } else {
            restoredReferenceImages = matchedProductID == nil
                && matchedAdAngleID == nil
                && matchedPromotionalContextIDs.isEmpty
                && !shouldRestoreRandomAdAngle
                && !shouldRestoreRandomPromotionalContext ? job.referenceImages : []
        }

        appModel.applySetup(
            prompt: job.inputPrompt,
            modelIDs: matchedModelIDs,
            cameraID: nil,
            productID: matchedProductID,
            adAngleID: matchedAdAngleID,
            randomAdAngle: shouldRestoreRandomAdAngle,
            promotionalContextIDs: matchedPromotionalContextIDs,
            randomPromotionalContext: shouldRestoreRandomPromotionalContext,
            shotMode: job.shotMode,
            audience: job.audience,
            presetIDs: matchedPresetIDs,
            randomModelMode: shouldRestoreRandomModel ? job.randomModelMode : .none,
            randomPresetCategories: Set(randomPresetCategories),
            referenceImageURLs: restoredReferenceImages.map(appModel.referenceImageURL(for:))
        )
        appModel.statusMessage = "Copied setup with \(restoredReferenceImages.count) manual reference photo\(restoredReferenceImages.count == 1 ? "" : "s")."
        appModel.lastError = nil
    }

    private func copySetupRandomPresetCategories(for pending: PendingGenerationBatch) -> [PromptPresetCategory] {
        if !pending.randomPresetCategories.isEmpty {
            return pending.randomPresetCategories
        }

        let groupedPresets = Dictionary(grouping: pending.presetSnapshots, by: \.category)
        return groupedPresets.compactMap { category, snapshots in
            Set(snapshots.map(\.name)).count > 1 ? category : nil
        }
    }

    private func copySetupRandomPresetCategories(for job: GenerationJob) -> [PromptPresetCategory] {
        if !job.randomPresetCategories.isEmpty {
            return job.randomPresetCategories
        }

        let groupedPresets = Dictionary(grouping: job.presetSnapshots, by: \.category)
        return groupedPresets.compactMap { category, snapshots in
            Set(snapshots.map(\.name)).count > 1 ? category : nil
        }
    }

    private func copyPromptWithJSONs(for pending: PendingGenerationBatch) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(pending.promptWithJSONs ?? pending.prompt, forType: .string)
        appModel.statusMessage = "Copied prompt with JSONs."
        appModel.lastError = nil
    }

    private func copyPromptWithJSONs(for job: GenerationJob) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(job.prompt, forType: .string)
        appModel.statusMessage = "Copied prompt with JSONs."
        appModel.lastError = nil
    }
}

private struct ReferencePhotoRow: View {
    let fileURL: URL
    let title: String
    let openAction: () -> Void
    let removeAction: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: openAction) {
                HStack(spacing: 10) {
                    GalleryThumbnailImage(
                        fileURL: fileURL,
                        cacheKey: "attached-reference-\(fileURL.lastPathComponent)",
                        maxPixelSize: 160
                    )
                    .frame(width: 42, height: 42)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.primary.opacity(0.08))
                    }

                    Text(title)
                        .font(.footnote)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the photo preview.")

            Button("Remove", action: removeAction)
                .buttonStyle(.borderless)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct GalleryThumbnailImage: View {
    let fileURL: URL
    let cacheKey: String
    var maxPixelSize = 720
    var contentMode: ContentMode = .fill

    @State private var thumbnail: NSImage?

    var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.08))
            .overlay {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                } else {
                    Image(systemName: "photo")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                }
            }
            .clipped()
            .task(id: cacheKey) {
                thumbnail = await GalleryThumbnailLoader.thumbnail(
                    for: fileURL,
                    cacheKey: cacheKey,
                    maxPixelSize: maxPixelSize
                )
            }
    }
}

private enum GalleryThumbnailLoader {
    @MainActor
    private static let cache = NSCache<NSString, NSImage>()

    @MainActor
    static func thumbnail(for fileURL: URL, cacheKey: String, maxPixelSize: Int) async -> NSImage? {
        let nsCacheKey = cacheKey as NSString
        if let cachedImage = cache.object(forKey: nsCacheKey) {
            return cachedImage
        }

        let image = await Task.detached(priority: .utility) { () -> NSImage? in
            guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else {
                return nil
            }

            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
            ]

            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return nil
            }

            let image = NSImage(
                cgImage: cgImage,
                size: NSSize(width: cgImage.width, height: cgImage.height)
            )
            return image
        }.value

        if let image {
            cache.setObject(image, forKey: nsCacheKey)
        }
        return image
    }
}

private enum ImagePreviewFactory {
    static func item(
        for fileURL: URL,
        displayName: String? = nil,
        fallbackImage: NSImage? = nil
    ) -> GalleryPreviewItem? {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let image = fallbackImage ?? NSImage(contentsOf: fileURL),
              let resolution = pixelSize(for: fileURL) ?? pixelSize(for: image) else {
            return nil
        }

        return GalleryPreviewItem(
            fileName: displayName ?? fileURL.lastPathComponent,
            image: image,
            resolution: resolution,
            fileURL: fileURL
        )
    }

    private static func pixelSize(for fileURL: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat else {
            return nil
        }

        return CGSize(width: width, height: height)
    }

    private static func pixelSize(for image: NSImage) -> CGSize? {
        if let representation = image.representations.first(where: {
            $0.pixelsWide > 0 && $0.pixelsHigh > 0
        }) {
            return CGSize(width: representation.pixelsWide, height: representation.pixelsHigh)
        }
        return nil
    }
}

private struct GalleryPreviewItem: Identifiable {
    let id = UUID()
    let fileName: String
    let image: NSImage
    let resolution: CGSize
    let fileURL: URL
}

private struct GalleryPromptPreview: Identifiable {
    let id: UUID
    let text: String
}

private struct GalleryPromptSheet: View {
    let item: GalleryPromptPreview
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Prompt")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(MediaforgeActionStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
            }

            ScrollView {
                Text(item.text)
                    .font(item.text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{")
                          ? .system(.body, design: .monospaced) : .body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(20)
        .frame(width: 580, height: 400)
    }
}

private struct ImagePreviewSheet: View {
    let item: GalleryPreviewItem
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.fileName)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)

                    Text("\(Int(item.resolution.width)) x \(Int(item.resolution.height)) px")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(MediaforgeActionStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
            }

            GeometryReader { proxy in
                let fittedSize = previewSize(in: proxy.size)

                VStack {
                    Spacer(minLength: 0)
                    Image(nsImage: item.image)
                        .resizable()
                        .interpolation(.high)
                        .antialiased(true)
                        .frame(width: fittedSize.width, height: fittedSize.height)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 16))
            }

            HStack {
                Button("Open in Preview") {
                    NSWorkspace.shared.open(item.fileURL)
                }

                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([item.fileURL])
                }

                Spacer()
            }
            .buttonStyle(MediaforgeActionStyle())
        }
        .padding(24)
        .frame(minWidth: 760, minHeight: 620)
    }

    private func previewSize(in availableSize: CGSize) -> CGSize {
        let effectiveScale = max(displayScale, 1)
        let maxSharpSize = CGSize(
            width: item.resolution.width / effectiveScale,
            height: item.resolution.height / effectiveScale
        )

        let boundedSize = CGSize(
            width: min(availableSize.width, maxSharpSize.width),
            height: min(availableSize.height, maxSharpSize.height)
        )

        guard item.resolution.width > 0, item.resolution.height > 0,
              boundedSize.width > 0, boundedSize.height > 0 else {
            return .zero
        }

        let widthRatio = boundedSize.width / item.resolution.width
        let heightRatio = boundedSize.height / item.resolution.height
        let scale = min(widthRatio, heightRatio)

        return CGSize(
            width: floor(item.resolution.width * scale),
            height: floor(item.resolution.height * scale)
        )
    }
}

private struct ModelManagerSheet: View {
    private enum Mode {
        case browse
        case edit
    }

    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var promptModelStore: PromptModelStore
    @Environment(\.dismiss) private var dismiss

    @State private var mode: Mode = .browse
    @State private var draftSelectedModelIDs: [UUID] = []
    @State private var editingSelectionID: UUID?
    @State private var editingID: UUID?
    @State private var name = ""
    @State private var promptJSON = ""
    @State private var thumbnailURL: URL?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Manage models")
                    .font(.title2.bold())
                Spacer()
                if mode == .browse {
                    browseHeaderButtons
                } else {
                    editHeaderButtons
                }
            }

            Group {
                if mode == .browse {
                    browseContent
                } else {
                    editContent
                }
            }
        }
        .padding(24)
        .frame(width: 900, height: 560)
        .tint(.mediaforgeAccent)
        .onAppear {
            draftSelectedModelIDs = appModel.selectedModelIDs
            if editingSelectionID == nil {
                editingSelectionID = promptModelStore.profiles.first?.id
            }
        }
    }

    private var browseHeaderButtons: some View {
        HStack(spacing: 10) {
            Button("Create model") {
                beginCreatingModel()
            }
            .buttonStyle(MediaforgeActionStyle())

            Button("Edit models") {
                mode = .edit
                if let selectedID = draftSelectedModelIDs.first,
                   let profile = promptModelStore.profile(with: selectedID) {
                    load(profile)
                    editingSelectionID = selectedID
                } else if let firstProfile = promptModelStore.profiles.first {
                    editingSelectionID = firstProfile.id
                    load(firstProfile)
                } else {
                    beginCreatingModel()
                }
            }
            .buttonStyle(MediaforgeActionStyle())

            Button("Clear selection") {
                draftSelectedModelIDs = []
            }
            .buttonStyle(MediaforgeActionStyle())
            .disabled(draftSelectedModelIDs.isEmpty)

            Button("Done") {
                commitSelection()
                dismiss()
            }
            .buttonStyle(MediaforgeActionStyle(prominent: true))
        }
    }

    private var editHeaderButtons: some View {
        HStack(spacing: 10) {
            Button("Back") {
                mode = .browse
                errorMessage = nil
            }
            .buttonStyle(MediaforgeActionStyle())

            Button("Done") {
                commitSelection()
                dismiss()
            }
            .buttonStyle(MediaforgeActionStyle(prominent: true))
        }
    }

    private var browseContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(AudienceKind.allCases) { audience in
                    modelSection(audience.title, profiles: models(for: audience))
                }

                if promptModelStore.profiles.isEmpty {
                    Text("No saved models yet. Create one to keep a thumbnail and prompt JSON together.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
            }
        }
    }

    private func models(for audience: AudienceKind) -> [PromptModelProfile] {
        promptModelStore.profiles.filter(audience.includes)
    }

    @ViewBuilder
    private func modelSection(_ title: String, profiles: [PromptModelProfile]) -> some View {
        if !profiles.isEmpty {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.top, title == AudienceKind.allCases.first?.title ? 4 : 10)

            ForEach(profiles) { profile in
                browseRow(for: profile)
            }
        }
    }

    private func browseRow(for profile: PromptModelProfile) -> some View {
        let isSelected = draftSelectedModelIDs.contains(profile.id)

        return Button {
            if isSelected {
                draftSelectedModelIDs.removeAll { $0 == profile.id }
            } else {
                draftSelectedModelIDs.append(profile.id)
            }
        } label: {
            HStack(spacing: 12) {
                if let image = promptModelStore.thumbnailImage(for: profile) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.secondary.opacity(0.12))
                        .frame(width: 52, height: 52)
                        .overlay {
                            Image(systemName: "person.crop.square")
                                .foregroundStyle(.secondary)
                        }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.name)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Text(profile.normalizedPromptJSON)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.mediaforgeAccent : Color.secondary.opacity(0.45))
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isSelected ? Color.mediaforgeAccent : Color.secondary.opacity(0.14), lineWidth: isSelected ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func commitSelection() {
        appModel.selectModels(draftSelectedModelIDs)
    }

    private var editContent: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Models")
                    .font(.headline)

                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(AudienceKind.allCases) { audience in
                            editModelSection(audience.title, profiles: models(for: audience))
                        }
                    }
                }

                HStack(spacing: 10) {
                    Button("Add model") {
                        beginCreatingModel()
                    }
                    .buttonStyle(MediaforgeActionStyle())
                }
            }
            .frame(width: 260)

            VStack(alignment: .leading, spacing: 12) {
                Text(editingID == nil ? "New model" : "Edit model")
                    .font(.headline)

                TextField("Model name", text: $name)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button(thumbnailURL == nil ? "Choose thumbnail" : "Change thumbnail") {
                        chooseThumbnail()
                    }
                    if let thumbnailURL {
                        Text(thumbnailURL.lastPathComponent)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Text("Prompt JSON")
                    .font(.headline)

                TextEditor(text: $promptJSON)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 220)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.25))
                    }

                Text("This JSON will be appended to the prompt whenever this model is selected. The thumbnail is imported into the app and only used as a local preview.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                HStack {
                    Button("Delete") {
                        deleteCurrentlyEditingModel()
                    }
                    .disabled(editingID == nil)

                    Spacer()

                    Button("Save model") {
                        save()
                    }
                    .buttonStyle(MediaforgeActionStyle(prominent: true))
                }
            }
        }
    }

    @ViewBuilder
    private func editModelSection(_ title: String, profiles: [PromptModelProfile]) -> some View {
        if !profiles.isEmpty {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.top, title == AudienceKind.allCases.first?.title ? 0 : 8)

            ForEach(profiles) { profile in
                editSidebarRow(for: profile)
            }
        }
    }

    private func editSidebarRow(for profile: PromptModelProfile) -> some View {
        let isSelected = editingSelectionID == profile.id

        return Button {
            editingSelectionID = profile.id
            load(profile)
        } label: {
            HStack(spacing: 10) {
                if let image = promptModelStore.thumbnailImage(for: profile) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.12))
                        .frame(width: 36, height: 36)
                        .overlay {
                            Image(systemName: "person.crop.square")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                }

                Text(profile.name)
                    .foregroundStyle(.primary)

                Spacer()
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.mediaforgeAccent : Color.secondary.opacity(0.12), lineWidth: isSelected ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func chooseThumbnail() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]

        if panel.runModal() == .OK {
            thumbnailURL = panel.url
        }
    }

    private func load(_ profile: PromptModelProfile) {
        mode = .edit
        editingSelectionID = profile.id
        editingID = profile.id
        name = profile.name
        promptJSON = profile.promptJSON
        thumbnailURL = promptModelStore.thumbnailURL(for: profile)
        errorMessage = nil
    }

    private func delete(_ profile: PromptModelProfile) {
        do {
            try promptModelStore.delete(profile)
            draftSelectedModelIDs.removeAll { $0 == profile.id }
            if editingID == profile.id {
                if let replacement = promptModelStore.profiles.first {
                    editingSelectionID = replacement.id
                    load(replacement)
                } else {
                    beginCreatingModel()
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteCurrentlyEditingModel() {
        guard let editingID,
              let profile = promptModelStore.profile(with: editingID) else {
            return
        }
        delete(profile)
    }

    private func save() {
        guard let thumbnailURL else {
            errorMessage = "Choose a thumbnail first."
            return
        }

        do {
            try promptModelStore.upsert(
                id: editingID,
                name: name,
                thumbnailSourceURL: thumbnailURL,
                promptJSON: promptJSON
            )
            if let savedProfile = promptModelStore.profiles.first(where: {
                $0.id == (editingID ?? editingSelectionID)
            }) {
                editingSelectionID = savedProfile.id
                load(savedProfile)
            } else if let matchedByName = promptModelStore.profiles.first(where: {
                $0.name == name.trimmingCharacters(in: .whitespacesAndNewlines)
            }) {
                editingSelectionID = matchedByName.id
                load(matchedByName)
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func beginCreatingModel() {
        mode = .edit
        editingSelectionID = nil
        editingID = nil
        name = ""
        promptJSON = ""
        thumbnailURL = nil
        errorMessage = nil
    }
}

private struct CameraManagerSheet: View {
    private enum Mode {
        case browse
        case edit
    }

    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var cameraProfileStore: CameraProfileStore
    @Environment(\.dismiss) private var dismiss

    @State private var mode: Mode = .browse
    @State private var draftSelectedCameraID: UUID?
    @State private var selectedStyleCategory: StyleUsageCategory = .withModel
    @State private var editingSelectionID: UUID?
    @State private var editingID: UUID?
    @State private var name = ""
    @State private var promptJSON = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Manage styles")
                    .font(.title2.bold())
                Spacer()
                if mode == .browse {
                    browseHeaderButtons
                } else {
                    editHeaderButtons
                }
            }

            Group {
                if mode == .browse {
                    browseContent
                } else {
                    editContent
                }
            }
        }
        .padding(24)
        .frame(width: 900, height: 560)
        .tint(.mediaforgeAccent)
        .onAppear {
            draftSelectedCameraID = appModel.selectedCameraID
            if let selectedID = draftSelectedCameraID,
               let profile = cameraProfileStore.profile(with: selectedID) {
                selectedStyleCategory = profile.usageCategory
            }
            if editingSelectionID == nil {
                editingSelectionID = cameraProfileStore.profiles.first?.id
            }
        }
    }

    private var browseHeaderButtons: some View {
        HStack(spacing: 10) {
            Button("Create style") {
                beginCreatingCamera()
            }
            .buttonStyle(MediaforgeActionStyle())

            Button("Edit styles") {
                mode = .edit
                if let selectedID = draftSelectedCameraID,
                   let profile = cameraProfileStore.profile(with: selectedID) {
                    load(profile)
                } else if let firstProfile = cameraProfileStore.profiles.first {
                    editingSelectionID = firstProfile.id
                    load(firstProfile)
                } else {
                    beginCreatingCamera()
                }
            }
            .buttonStyle(MediaforgeActionStyle())

            Button("Done") {
                appModel.selectCamera(draftSelectedCameraID)
                dismiss()
            }
            .buttonStyle(MediaforgeActionStyle(prominent: true))
        }
    }

    private var editHeaderButtons: some View {
        HStack(spacing: 10) {
            Button("Back") {
                mode = .browse
                errorMessage = nil
            }
            .buttonStyle(MediaforgeActionStyle())

            Button("Done") {
                appModel.selectCamera(draftSelectedCameraID)
                dismiss()
            }
            .buttonStyle(MediaforgeActionStyle(prominent: true))
        }
    }

    private var browseContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Styles are organized as one style folder, with optional audience subfolders like All, Musicians, Gamers, Worship, or Motorcyclists. The JSON is appended to the prompt when selected.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Picker("Style category", selection: $selectedStyleCategory) {
                    ForEach(StyleUsageCategory.allCases) { category in
                        Text(category.title).tag(category)
                    }
                }
                .pickerStyle(.segmented)

                Text(selectedStyleCategory.subtitle)
                    .font(.footnote)
                    .foregroundStyle(selectedStyleCategory == .withModel ? .secondary : Color.orange)

                ForEach(filteredStyleProfiles) { profile in
                    browseRow(for: profile)
                }

                if cameraProfileStore.profiles.isEmpty {
                    Text("No saved styles yet. Create one to keep reusable style JSON.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                } else if filteredStyleProfiles.isEmpty {
                    Text("No styles in this category yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
            }
        }
    }

    private var filteredStyleProfiles: [CameraProfile] {
        cameraProfileStore.profiles.filter { profile in
            profile.usageCategory == selectedStyleCategory && (profile.inferredAudience == nil || profile.inferredAudience == appModel.form.audience)
        }
    }

    private func browseRow(for profile: CameraProfile) -> some View {
        let isSelected = draftSelectedCameraID == profile.id

        return Button {
            draftSelectedCameraID = isSelected ? nil : profile.id
        } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.secondary.opacity(0.12))
                    .frame(width: 52, height: 52)
                    .overlay {
                        Image(systemName: "wand.and.stars")
                            .foregroundStyle(.secondary)
                    }

                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.name)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Text(profile.audienceLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text(profile.normalizedPromptJSON)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.mediaforgeAccent : Color.secondary.opacity(0.45))
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isSelected ? Color.mediaforgeAccent : Color.secondary.opacity(0.14), lineWidth: isSelected ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
    }

    private var editContent: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Styles")
                    .font(.headline)

                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(cameraProfileStore.profiles) { profile in
                            editSidebarRow(for: profile)
                        }
                    }
                }

                Button("Add style") {
                    beginCreatingCamera()
                }
                .buttonStyle(MediaforgeActionStyle())
            }
            .frame(width: 260)

            VStack(alignment: .leading, spacing: 12) {
                Text(editingID == nil ? "New style" : "Edit style")
                    .font(.headline)

                TextField("Style name", text: $name)
                    .textFieldStyle(.roundedBorder)

                Text("Style JSON")
                    .font(.headline)

                TextEditor(text: $promptJSON)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 260)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.25))
                    }

                Text("Use this for camera feel, common angles, lighting, props, environments, textures, and repeatable image-generation constraints.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                HStack {
                    Button("Delete") {
                        deleteCurrentlyEditingCamera()
                    }
                    .disabled(editingID == nil)

                    Spacer()

                    Button("Save style") {
                        save()
                    }
                    .buttonStyle(MediaforgeActionStyle(prominent: true))
                }
            }
        }
    }

    private func editSidebarRow(for profile: CameraProfile) -> some View {
        let isSelected = editingSelectionID == profile.id

        return Button {
            editingSelectionID = profile.id
            load(profile)
        } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.12))
                    .frame(width: 36, height: 36)
                    .overlay {
                        Image(systemName: "wand.and.stars")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                Text(profile.name)
                    .foregroundStyle(.primary)

                Spacer()
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.mediaforgeAccent : Color.secondary.opacity(0.12), lineWidth: isSelected ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func load(_ profile: CameraProfile) {
        mode = .edit
        editingSelectionID = profile.id
        editingID = profile.id
        name = profile.name
        promptJSON = profile.promptJSON
        errorMessage = nil
    }

    private func delete(_ profile: CameraProfile) {
        do {
            try cameraProfileStore.delete(profile)
            if draftSelectedCameraID == profile.id {
                draftSelectedCameraID = nil
            }
            if editingID == profile.id {
                if let replacement = cameraProfileStore.profiles.first {
                    editingSelectionID = replacement.id
                    load(replacement)
                } else {
                    beginCreatingCamera()
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteCurrentlyEditingCamera() {
        guard let editingID,
              let profile = cameraProfileStore.profile(with: editingID) else {
            return
        }
        delete(profile)
    }

    private func save() {
        do {
            try cameraProfileStore.upsert(
                id: editingID,
                name: name,
                promptJSON: promptJSON
            )
            if let savedProfile = cameraProfileStore.profiles.first(where: {
                $0.id == (editingID ?? editingSelectionID)
            }) {
                editingSelectionID = savedProfile.id
                load(savedProfile)
            } else if let matchedByName = cameraProfileStore.profiles.first(where: {
                $0.name == name.trimmingCharacters(in: .whitespacesAndNewlines)
            }) {
                editingSelectionID = matchedByName.id
                load(matchedByName)
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func beginCreatingCamera() {
        mode = .edit
        editingSelectionID = nil
        editingID = nil
        name = ""
        promptJSON = ""
        errorMessage = nil
    }
}
