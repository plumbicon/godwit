import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

private let subscriptionDetailValueColumnWidth: CGFloat = 200
#if os(iOS)
private let subscriptionDetailTextFieldWidth: CGFloat = 148
private let subscriptionDetailLabelMinWidth: CGFloat = 0
private let subscriptionDetailRowSpacing: CGFloat = 8
private let subscriptionDetailSpacerMinLength: CGFloat = 8
#else
private let subscriptionDetailTextFieldWidth: CGFloat = subscriptionDetailValueColumnWidth
private let subscriptionDetailLabelMinWidth: CGFloat = 170
private let subscriptionDetailRowSpacing: CGFloat = 12
private let subscriptionDetailSpacerMinLength: CGFloat = 16
#endif

public struct ContentView: View {
    @StateObject private var viewModel: ClientViewModel
    @State private var isShowingImporter = false
    @State private var isShowingProfileCreator = false
    @State private var isShowingLogs = false
    @State private var isShowingSettings = false
    @State private var detailDestination: DetailDestination?

    @MainActor
    public init() {
        _viewModel = StateObject(wrappedValue: ClientViewModel())
    }

    @MainActor
    public init(viewModel: ClientViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    public var body: some View {
        NavigationStack {
            Group {
                if viewModel.profiles.isEmpty {
                    EmptyProfilesView(
                        onAddProfile: { isShowingProfileCreator = true },
                        onImportProfile: { isShowingImporter = true }
                    )
                } else {
                    ProfilesHomeView(
                        viewModel: viewModel,
                        subscriptionGroups: subscriptionGroups,
                        ungroupedProfiles: ungroupedProfiles,
                        onShowProfileDetails: showProfileDetails,
                        onShowSubscriptionDetails: showSubscriptionDetails,
                        onRefreshSubscription: viewModel.refreshSubscription,
                        onPingProfile: viewModel.pingProfile,
                        onPingSubscription: viewModel.pingSubscription,
                        onDeleteSubscription: viewModel.deleteSubscription
                    )
                }
            }
            .navigationTitle("Godwit")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                #if os(iOS)
                ToolbarItemGroup(placement: .navigationBarLeading) {
                    Button {
                        isShowingSettings = true
                    } label: {
                        Label("Настройки", systemImage: "gearshape")
                    }
                    .disabled(viewModel.selectedProfileID == nil)

                    Button {
                        isShowingLogs = true
                    } label: {
                        Label("Журнал", systemImage: "list.bullet.rectangle")
                    }
                }

                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        isShowingProfileCreator = true
                    } label: {
                        Label("Добавить профиль", systemImage: "plus")
                    }

                    Button {
                        isShowingImporter = true
                    } label: {
                        Label("Импортировать", systemImage: "square.and.arrow.down")
                    }
                }
                #else
                ToolbarItemGroup(placement: .navigation) {
                    Button {
                        isShowingSettings = true
                    } label: {
                        Label("Настройки", systemImage: "gearshape")
                    }
                    .disabled(viewModel.selectedProfileID == nil)

                    Button {
                        isShowingLogs = true
                    } label: {
                        Label("Журнал", systemImage: "list.bullet.rectangle")
                    }
                }

                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        isShowingProfileCreator = true
                    } label: {
                        Label("Добавить профиль", systemImage: "plus")
                    }

                    Button {
                        isShowingImporter = true
                    } label: {
                        Label("Импортировать", systemImage: "square.and.arrow.down")
                    }
                }
                #endif
            }
        }
        #if os(iOS)
        .dynamicTypeSize(.small ... .large)
        .controlSize(.small)
        #endif
        .sheet(isPresented: $isShowingImporter) {
            ImportProfileSheet(isImporting: viewModel.isImporting) { value in
                viewModel.importValue(value)
                isShowingImporter = false
            }
        }
        .sheet(isPresented: $isShowingProfileCreator) {
            CreateProfileSheet(
                initialProfile: initialCreatedProfile,
                validationMessage: viewModel.validationMessage(for:),
                onCancel: { isShowingProfileCreator = false },
                onCreate: { profile in
                    viewModel.createProfile(profile)
                    isShowingProfileCreator = false
                }
            )
        }
        .sheet(item: $detailDestination) { destination in
            detailView(for: destination)
        }
        .sheet(isPresented: $isShowingSettings) {
            ProfileSettingsScreen(viewModel: viewModel)
        }
        .logPresentation(isPresented: $isShowingLogs) {
            LogScreen(logs: viewModel.logs) {
                viewModel.clearLogs()
            }
        }
        .overlay(alignment: .top) {
            if let message = viewModel.importErrorMessage {
                ImportErrorBanner(message: message) {
                    viewModel.clearImportError()
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            viewModel.shutdownForAppTermination()
        }
        #elseif os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
            viewModel.shutdownForAppTermination()
        }
        #endif
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: viewModel.importErrorMessage)
    }

    private var ungroupedProfiles: [ConnectionProfile] {
        viewModel.profiles.filter { $0.subscription == nil }
    }

    private var subscriptionGroups: [SubscriptionGroup] {
        var groups: [SubscriptionGroup] = []
        for profile in viewModel.profiles {
            guard let subscription = profile.subscription else {
                continue
            }

            if let index = groups.firstIndex(where: { $0.id == subscription.id }) {
                groups[index].profiles.append(profile)
            } else {
                groups.append(SubscriptionGroup(metadata: subscription, profiles: [profile]))
            }
        }
        return groups
    }

    private var initialCreatedProfile: ConnectionProfile {
        var profile = ConnectionProfile.empty
        profile.name = AppLocalization.format("Profile %d", viewModel.profiles.count + 1)
        return profile
    }

    private func showProfileDetails(_ profile: ConnectionProfile) {
        viewModel.selectProfile(profile.id)
        detailDestination = .profile(profile.id)
    }

    private func showSubscriptionDetails(_ group: SubscriptionGroup) {
        detailDestination = .subscription(group.id)
    }

    @ViewBuilder
    private func detailView(for destination: DetailDestination) -> some View {
        NavigationStack {
            switch destination {
            case .profile:
                ProfileDetailScreen(viewModel: viewModel)

            case .subscription(let id):
                if let group = subscriptionGroups.first(where: { $0.id == id }) {
                    SubscriptionDetailView(
                        group: group,
                        isRefreshing: viewModel.refreshingSubscriptionIDs.contains(id),
                        onRefresh: { viewModel.refreshSubscription(id) },
                        onUpdateSource: { sourceURL in
                            viewModel.updateSubscriptionSource(id, sourceURL: sourceURL)
                        },
                        onDelete: {
                            viewModel.deleteSubscription(id)
                            detailDestination = nil
                        }
                    )
                    .navigationTitle(group.metadata.name)
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                } else {
                    UnavailableDetailView()
                        .navigationTitle("Подробности")
                }
            }
        }
    }
}

private struct ProfileDetailScreen: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: ClientViewModel

    var body: some View {
        ProfileEditorView(
            profile: $viewModel.draft,
            useSystemProxy: $viewModel.useSystemProxy,
            selectedNetworkService: $viewModel.selectedNetworkService,
            networkServices: viewModel.networkServices,
            validationMessage: viewModel.validationMessage,
            onCommit: viewModel.saveDraft
        )
        .navigationTitle(viewModel.selectedProfileName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Готово") {
                    viewModel.saveDraft()
                    dismiss()
                }
            }
        }
    }
}

private struct ProfileSettingsScreen: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: ClientViewModel
    @State private var socksPortInput = ""
    @FocusState private var isSocksPortFocused: Bool

    private var socksPortText: Binding<String> {
        Binding(
            get: {
                if socksPortInput.isEmpty && !isSocksPortFocused {
                    return "\(viewModel.draft.socksPort)"
                }
                return socksPortInput
            },
            set: { newValue in
                socksPortInput = newValue.filter(\.isNumber)
            }
        )
    }

    private var socksPortStepperValue: Binding<Int> {
        Binding(
            get: { viewModel.draft.socksPort },
            set: setSocksPort
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("SOCKS") {
                    HStack {
                        Text("Порт")

                        Spacer(minLength: 16)

                        HStack(spacing: 8) {
                            TextField("", text: socksPortText)
                                .settingsPlainInput()
                                .multilineTextAlignment(.trailing)
                                .frame(width: 78)
                                .focused($isSocksPortFocused)
                                #if os(iOS)
                                .keyboardType(.numberPad)
                                #endif
                                .onSubmit(saveSettings)

                            Stepper("", value: socksPortStepperValue, in: ConnectionProfile.socksPortRange)
                                .labelsHidden()
                                .fixedSize()

                            randomPortButton
                        }
                    }

                    TextField("Имя пользователя", text: $viewModel.draft.socksUser)
                        .settingsPlainInput()
                        .onSubmit(viewModel.saveDraft)

                    SecureField("Пароль", text: $viewModel.draft.socksPass)
                        .settingsPlainInput()
                        .onSubmit(viewModel.saveDraft)
                }

                #if os(macOS)
                Section("Системный прокси") {
                    Toggle("Направлять системный трафик через SOCKS", isOn: $viewModel.useSystemProxy)

                    Picker("Сетевой сервис", selection: $viewModel.selectedNetworkService) {
                        ForEach(viewModel.networkServices, id: \.self) { service in
                            Text(service).tag(service)
                        }
                    }
                    .disabled(!viewModel.useSystemProxy)
                }
                #elseif os(iOS)
                Section("VPN") {
                    Toggle("Направлять системный трафик через VPN", isOn: $viewModel.useSystemProxy)
                }
                #endif

                Section("Запуск") {
                    TextField("DNS-сервер", text: $viewModel.draft.dnsServer)
                        .settingsPlainInput()
                        .onSubmit(viewModel.saveDraft)

                    Toggle("Подробный журнал", isOn: $viewModel.draft.debugLogging)

                    HStack {
                        Text("Таймаут запуска")

                        Spacer(minLength: 16)

                        HStack(spacing: 8) {
                            Text("\(viewModel.draft.startTimeoutMillis / 1_000)s")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 44, alignment: .trailing)

                            Stepper("", value: $viewModel.draft.startTimeoutMillis, in: 10_000...300_000, step: 5_000)
                                .labelsHidden()
                                .fixedSize()
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Настройки")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") {
                        saveSettings()
                        dismiss()
                    }
                }
            }
            .onAppear(perform: syncSocksPortInput)
            .onChange(of: isSocksPortFocused) { isFocused in
                if isFocused {
                    syncSocksPortInput()
                } else {
                    commitSocksPortInput()
                }
            }
            .onChange(of: viewModel.draft.socksPort) { newValue in
                if !isSocksPortFocused {
                    socksPortInput = "\(newValue)"
                }
            }
            .onDisappear(perform: saveSettings)
        }
        #if os(macOS)
        .frame(width: 460, height: 500)
        #endif
    }

    private func setSocksPort(_ port: Int) {
        let clampedPort = ConnectionProfile.clampedSocksPort(port)
        viewModel.draft.socksPort = clampedPort
        socksPortInput = "\(clampedPort)"
    }

    private func syncSocksPortInput() {
        socksPortInput = "\(viewModel.draft.socksPort)"
    }

    private func commitSocksPortInput() {
        let digits = socksPortInput.filter(\.isNumber)
        guard let port = Int(digits) else {
            syncSocksPortInput()
            return
        }
        setSocksPort(port)
    }

    private func saveSettings() {
        commitSocksPortInput()
        viewModel.saveDraft()
    }

    private var randomPortButton: some View {
        Button {
            isSocksPortFocused = false
            setSocksPort(PortAvailability.randomAvailableTCPPort())
            viewModel.saveDraft()
        } label: {
            Label("Свободный порт", systemImage: "wand.and.stars")
                #if os(iOS)
                .labelStyle(.iconOnly)
                #else
                .labelStyle(.titleAndIcon)
                #endif
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        #if os(iOS)
        .frame(width: 36, height: 30)
        #endif
        .accessibilityLabel("Свободный порт")
        #if os(macOS)
        .help("Выбрать случайный свободный порт")
        #endif
    }
}

private struct CreateProfileSheet: View {
    @State private var profile: ConnectionProfile

    let validationMessage: (ConnectionProfile) -> String?
    let onCancel: () -> Void
    let onCreate: (ConnectionProfile) -> Void

    init(
        initialProfile: ConnectionProfile,
        validationMessage: @escaping (ConnectionProfile) -> String?,
        onCancel: @escaping () -> Void,
        onCreate: @escaping (ConnectionProfile) -> Void
    ) {
        _profile = State(initialValue: initialProfile)
        self.validationMessage = validationMessage
        self.onCancel = onCancel
        self.onCreate = onCreate
    }

    private var currentValidationMessage: String? {
        validationMessage(profile)
    }

    var body: some View {
        NavigationStack {
            ProfileEditorView(
                profile: $profile,
                useSystemProxy: .constant(false),
                selectedNetworkService: .constant("Wi-Fi"),
                networkServices: [],
                validationMessage: nil,
                startsAdvancedExpanded: true,
                onCommit: {}
            )
            .navigationTitle("Новый профиль")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена", role: .cancel, action: onCancel)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") {
                        onCreate(profile)
                    }
                    .disabled(currentValidationMessage != nil)
                }
            }
        }
        #if os(macOS)
        .frame(width: 460, height: 500)
        #endif
    }
}

private enum DetailDestination: Identifiable {
    case profile(UUID)
    case subscription(UUID)

    var id: String {
        switch self {
        case .profile(let id): "profile-\(id.uuidString)"
        case .subscription(let id): "subscription-\(id.uuidString)"
        }
    }
}

private struct ProfilesHomeView: View {
    @ObservedObject var viewModel: ClientViewModel
    let subscriptionGroups: [SubscriptionGroup]
    let ungroupedProfiles: [ConnectionProfile]
    let onShowProfileDetails: (ConnectionProfile) -> Void
    let onShowSubscriptionDetails: (SubscriptionGroup) -> Void
    let onRefreshSubscription: (UUID) -> Void
    let onPingProfile: (UUID) -> Void
    let onPingSubscription: (UUID) -> Void
    let onDeleteSubscription: (UUID) -> Void

    var body: some View {
        List {
            ConnectionPanel(viewModel: viewModel)
                .listRowSeparator(.hidden, edges: .bottom)
                #if os(iOS)
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                #endif

            if !ungroupedProfiles.isEmpty {
                Section("Профили") {
                    ForEach(Array(ungroupedProfiles.enumerated()), id: \.element.id) { index, profile in
                        ProfileSelectionRow(
                            profile: profile,
                            isSelected: viewModel.selectedProfileID == profile.id,
                            showsInfo: true,
                            showsPing: true,
                            isPinging: viewModel.pingingProfileIDs.contains(profile.id),
                            pingState: viewModel.pingResults[profile.id],
                            onSelect: { viewModel.selectProfile(profile.id) },
                            onPing: { onPingProfile(profile.id) },
                            onInfo: { onShowProfileDetails(profile) }
                        )
                        .profileListRowChrome(
                            isSelected: viewModel.selectedProfileID == profile.id,
                            topSeparator: index == 0 ? .visible : .hidden
                        )
                        .swipeActions {
                            Button("Удалить", role: .destructive) {
                                viewModel.deleteProfiles(ids: [profile.id])
                            }
                        }
                    }
                    .onDelete { offsets in
                        let ids = offsets.compactMap { ungroupedProfiles.indices.contains($0) ? ungroupedProfiles[$0].id : nil }
                        viewModel.deleteProfiles(ids: ids)
                    }
                }
            }

            ForEach(Array(subscriptionGroups.enumerated()), id: \.element.id) { index, group in
                Section {
                    SubscriptionSelectionRow(
                        group: group,
                        isRefreshing: viewModel.refreshingSubscriptionIDs.contains(group.id),
                        isPinging: group.profiles.contains { viewModel.pingingProfileIDs.contains($0.id) },
                        onRefresh: { onRefreshSubscription(group.id) },
                        onPing: { onPingSubscription(group.id) },
                        onInfo: { onShowSubscriptionDetails(group) }
                    )
                    .listRowSeparator(.hidden, edges: .bottom)
                    #if os(iOS)
                    .listRowInsets(ProfileListLayout.rowInsets)
                    #endif
                    .swipeActions {
                        Button("Удалить", role: .destructive) {
                            onDeleteSubscription(group.id)
                        }
                    }

                    ForEach(group.profiles) { profile in
                        ProfileSelectionRow(
                            profile: profile,
                            isSelected: viewModel.selectedProfileID == profile.id,
                            showsInfo: false,
                            showsPing: false,
                            leadingIndent: ProfileListLayout.subscriptionProfileIndent,
                            isPinging: viewModel.pingingProfileIDs.contains(profile.id),
                            pingState: viewModel.pingResults[profile.id],
                            onSelect: { viewModel.selectProfile(profile.id) },
                            onPing: { onPingProfile(profile.id) },
                            onInfo: { onShowProfileDetails(profile) }
                        )
                        .profileListRowChrome(isSelected: viewModel.selectedProfileID == profile.id)
                        .swipeActions {
                            Button("Удалить", role: .destructive) {
                                viewModel.deleteProfiles(ids: [profile.id])
                            }
                        }
                    }
                } header: {
                    if index == 0 {
                        Text("Подписки")
                    }
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
    }
}

private struct ConnectionPanel: View {
    @ObservedObject var viewModel: ClientViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    StatusBadge(status: viewModel.status)

                    if viewModel.selectedProfileID != nil {
                        Text(connectionDetail)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                            .allowsTightening(true)
                    }
                }
                .layoutPriority(1)

                Spacer(minLength: 8)

                connectionButton
            }

            if let validationMessage = viewModel.validationMessage, viewModel.selectedProfileID != nil {
                Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var connectionButton: some View {
        if viewModel.status.isRunning {
            Button(action: viewModel.stop) {
                Image(systemName: "power")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 36, height: 30)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .accessibilityLabel("Отключить")
            .disabled(viewModel.status == .stopping)
        } else {
            Button(action: viewModel.start) {
                Image(systemName: "power")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 36, height: 30)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .accessibilityLabel("Подключить")
            .disabled(!viewModel.canStart)
        }
    }

    private var connectionDetail: String {
        [
            viewModel.selectedProfileName,
            viewModel.draft.carrier.title,
            viewModel.draft.transport.title,
        ].joined(separator: " · ")
    }
}

private struct EmptyProfilesView: View {
    let onAddProfile: () -> Void
    let onImportProfile: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 32)

            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 46, weight: .regular))
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                Text("Профилей пока нет")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)

                VStack(spacing: 2) {
                    HStack(spacing: 0) {
                        InlineTextButton("Импортируйте", action: onImportProfile)
                        Text(" подписку или ")
                            .foregroundStyle(.secondary)
                        InlineTextButton("добавьте", action: onAddProfile)
                    }

                    Text("профиль вручную.")
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
                .multilineTextAlignment(.center)
            }

            Spacer(minLength: 32)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct InlineTextButton: View {
    let title: LocalizedStringKey
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = LocalizedStringKey(title)
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .foregroundStyle(.tint)
        }
        .buttonStyle(.plain)
    }
}

private struct ImportProfileSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var importText = ""

    let isImporting: Bool
    let onImport: (String) -> Void

    private var canImport: Bool {
        !importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isImporting
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ZStack(alignment: .topLeading) {
                        ImportTextInput(
                            text: $importText,
                            onSubmit: importValue
                        )

                        if importText.isEmpty {
                            Text("Вставьте olcRTC-ссылку, URL подписки или текст sub.md")
                                .foregroundStyle(.tertiary)
                                .lineLimit(3)
                                .allowsHitTesting(false)
                        }
                    }
                    .font(.body)
                    .frame(minHeight: 120, alignment: .topLeading)
                } footer: {
                    Text("Поддерживаются olcrtc://, http/https-ссылки на подписку и содержимое sub.md.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Импорт")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена", role: .cancel) {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    Button(action: importValue) {
                        ImportLabel(isImporting: isImporting)
                    }
                    .disabled(!canImport)
                }
            }
        }
        #if os(macOS)
        .frame(width: 460, height: 300)
        #endif
    }

    private func importValue() {
        let value = importText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return
        }

        onImport(value)
        dismiss()
    }
}

private struct ImportTextInput: View {
    @Binding var text: String
    let onSubmit: () -> Void

    var body: some View {
        #if os(macOS)
        MacImportTextInput(text: $text)
            .frame(maxWidth: .infinity, alignment: .leading)
        #else
        TextField("", text: $text, axis: .vertical)
            .lineLimit(5...10)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.leading)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onSubmit(onSubmit)
        #endif
    }
}

#if os(macOS)
private struct MacImportTextInput: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.string = text
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textColor = .labelColor
        textView.allowsUndo = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else {
            return
        }

        if textView.string != text {
            textView.string = text
        }

        textView.font = .preferredFont(forTextStyle: .body)
        textView.textColor = .labelColor
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else {
                return
            }

            text.wrappedValue = textView.string
        }
    }
}
#endif

private struct ImportLabel: View {
    let isImporting: Bool

    var body: some View {
        if isImporting {
            Label("Импорт...", systemImage: "arrow.triangle.2.circlepath")
        } else {
            Label("Импортировать", systemImage: "square.and.arrow.down")
        }
    }
}

private struct SubscriptionGroup: Identifiable {
    var metadata: SubscriptionMetadata
    var profiles: [ConnectionProfile]

    var id: UUID { metadata.id }
}

private struct SubscriptionSelectionRow: View {
    let group: SubscriptionGroup
    let isRefreshing: Bool
    let isPinging: Bool
    let onRefresh: () -> Void
    let onPing: () -> Void
    let onInfo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            SubscriptionMarker(metadata: group.metadata)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(group.metadata.name)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                        .layoutPriority(1)

                    if let lastRefreshDisplayDate {
                        Text("·")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: true, vertical: false)

                        TimelineView(.periodic(from: Date(), by: 30)) { timeline in
                            Text(lastRefreshText(since: lastRefreshDisplayDate, now: timeline.date))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                }

                Text(subscriptionDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                Button(action: onRefresh) {
                    Image(systemName: isRefreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(isRefreshing || group.metadata.sourceURL == nil)
                .accessibilityLabel("Обновить подписку")

                PingButton(isPinging: isPinging, action: onPing)
                    .accessibilityLabel("Пинг подписки")

                InfoButton(action: onInfo)
            }
        }
        #if os(iOS)
        .padding(.leading, ProfileListLayout.contentLeadingPadding)
        .padding(.trailing, ProfileListLayout.contentTrailingPadding)
        #endif
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var subscriptionDetail: String {
        let serverTitle = pluralizedServers(group.profiles.count)
        if let available = group.metadata.available {
            return "\(serverTitle) · \(available)"
        }
        return serverTitle
    }

    private var lastRefreshDisplayDate: Date? {
        guard SubscriptionRefreshInterval.seconds(from: group.metadata.refreshInterval) != nil else {
            return nil
        }
        return group.metadata.lastFetchedAtUnix.map(Date.init(timeIntervalSince1970:))
    }

    private func lastRefreshText(since date: Date, now: Date) -> String {
        let elapsed = max(0, now.timeIntervalSince(date))
        return AppLocalization.format(
            "updated %@ ago",
            SubscriptionRefreshInterval.abbreviatedString(from: elapsed)
        )
    }
}

private struct ProfileSelectionRow: View {
    let profile: ConnectionProfile
    let isSelected: Bool
    let showsInfo: Bool
    let showsPing: Bool
    var leadingIndent: CGFloat = 0
    let isPinging: Bool
    let pingState: ProfilePingState?
    let onSelect: () -> Void
    let onPing: () -> Void
    let onInfo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onSelect) {
                HStack(spacing: 12) {
                    SubscriptionMarker(
                        metadata: profile.subscription,
                        fallbackSystemImage: "network",
                        isSelected: isSelected
                    )

                    VStack(alignment: .leading, spacing: 3) {
                        Text(profile.displayName)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text(profile.listDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                            .allowsTightening(true)
                    }
                    .layoutPriority(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 4) {
                PingStateLabel(
                    state: pingState,
                    isPinging: isPinging,
                    compact: !showsPing && !showsInfo
                )
                if showsPing {
                    PingButton(isPinging: isPinging, action: onPing)
                        .accessibilityLabel("Пинг профиля")
                }
                if showsInfo {
                    InfoButton(action: onInfo)
                }
            }
        }
        .padding(.leading, leadingIndent)
        #if os(iOS)
        .padding(.leading, ProfileListLayout.contentLeadingPadding)
        .padding(.trailing, ProfileListLayout.contentTrailingPadding)
        #endif
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            #if os(macOS)
            if isSelected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.10))
            }
            #endif
        }
    }
}

private extension View {
    @ViewBuilder
    func profileListRowChrome(isSelected: Bool, topSeparator: Visibility = .hidden) -> some View {
        #if os(iOS)
        self
            .listRowSeparator(.hidden, edges: .top)
            .listRowSeparator(.hidden, edges: .bottom)
            .listRowInsets(ProfileListLayout.rowInsets)
            .profileListRowBackground(isSelected: isSelected)
        #else
        self
            .listRowSeparator(topSeparator, edges: .top)
            .listRowSeparator(.hidden, edges: .bottom)
        #endif
    }

    @ViewBuilder
    private func profileListRowBackground(isSelected: Bool) -> some View {
        if isSelected {
            self.listRowBackground(Color.accentColor.opacity(0.10))
        } else {
            self
        }
    }
}

private enum ProfileListLayout {
    static let markerSize: CGFloat = 28
    static let markerSpacing: CGFloat = 12
    static let subscriptionProfileIndent = markerSize + markerSpacing

    #if os(iOS)
    static let contentLeadingPadding: CGFloat = 16
    static let contentTrailingPadding: CGFloat = 10
    static let rowInsets = EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0)
    #endif
}

private struct InfoButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "info.circle")
                .font(.system(size: 18, weight: .medium))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Подробности")
    }
}

private struct PingButton: View {
    let isPinging: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "speedometer")
                .font(.system(size: 17, weight: .medium))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.secondary)
        .opacity(isPinging ? 0.45 : 1)
        .disabled(isPinging)
    }
}

private struct PingStateLabel: View {
    let state: ProfilePingState?
    let isPinging: Bool
    var compact = false

    var body: some View {
        Group {
            if isPinging {
                ProgressView()
                    .controlSize(.small)
            } else if let state {
                switch state {
                case .success(let milliseconds):
                    Text(AppLocalization.format("%d ms", milliseconds))
                        .foregroundStyle(color(for: milliseconds))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .help(AppLocalization.format("Last ping: %d ms", milliseconds))

                case .failure(let message):
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .help(message)
                }
            } else {
                Color.clear
            }
        }
        .font(.caption.weight(.semibold))
        .padding(.trailing, trailingPadding)
        .frame(width: width, height: 30, alignment: alignment)
    }

    private var width: CGFloat {
        if compact, isSuccessText {
            return 56
        }
        if compact || isPinging {
            return 30
        }
        if case .failure = state {
            return 30
        }
        return 56
    }

    private var alignment: Alignment {
        width == 30 ? .center : .trailing
    }

    private var trailingPadding: CGFloat {
        compact && isSuccessText ? 8 : 0
    }

    private var isSuccessText: Bool {
        if case .success = state {
            return true
        }
        return false
    }

    private func color(for milliseconds: Int) -> Color {
        if milliseconds < 150 {
            return .green
        }
        if milliseconds < 350 {
            return .orange
        }
        return .red
    }
}

private struct ImportErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            Text(message)
                .font(.callout.weight(.medium))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Закрыть")
        }
        .padding(.vertical, 12)
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 16, x: 0, y: 8)
    }
}

private struct SubscriptionDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var sourceURL: String

    let group: SubscriptionGroup
    let isRefreshing: Bool
    let onRefresh: () -> Void
    let onUpdateSource: (String?) -> Void
    let onDelete: () -> Void

    init(
        group: SubscriptionGroup,
        isRefreshing: Bool,
        onRefresh: @escaping () -> Void,
        onUpdateSource: @escaping (String?) -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.group = group
        self.isRefreshing = isRefreshing
        self.onRefresh = onRefresh
        self.onUpdateSource = onUpdateSource
        self.onDelete = onDelete
        _sourceURL = State(initialValue: group.metadata.sourceURL ?? "")
    }

    var body: some View {
        Form {
            Section("Подписка") {
                LabeledContent("Название", value: group.metadata.name)

                SubscriptionSourceTextRow(
                    title: "Источник",
                    text: $sourceURL,
                    onCommit: saveSourceAndRefresh
                )

                LabeledContent("Серверы", value: "\(group.profiles.count)")

                if let refreshInterval = SubscriptionRefreshInterval.localizedString(from: group.metadata.refreshInterval) {
                    LabeledContent("Интервал автообновления", value: refreshInterval)
                }

                if let available = group.metadata.available {
                    LabeledContent("Доступно", value: available)
                }

                if let used = group.metadata.used {
                    LabeledContent("Использовано", value: used)
                }
            }

            Section("Действия") {
                Button {
                    saveSourceAndRefresh()
                } label: {
                    Label(
                        LocalizedStringKey(isRefreshing ? "Обновление..." : "Обновить подписку"),
                        systemImage: "arrow.clockwise"
                    )
                }
                .disabled(isRefreshing || sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button {
                    saveSourceAndRefresh()
                } label: {
                    Label("Сохранить источник и обновить", systemImage: "square.and.arrow.down")
                }
                .disabled(isRefreshing || sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button(role: .destructive) {
                    onDelete()
                    dismiss()
                } label: {
                    Label("Удалить подписку", systemImage: "trash")
                }
            }
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Готово") {
                    dismiss()
                }
            }
        }
    }

    private func saveSourceAndRefresh() {
        let normalizedSourceURL = sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSourceURL.isEmpty else {
            return
        }

        onUpdateSource(normalizedSourceURL)
        onRefresh()
    }
}

private struct SubscriptionSourceTextRow: View {
    let title: String
    @Binding var text: String
    let onCommit: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .center, spacing: subscriptionDetailRowSpacing) {
            Text(LocalizedStringKey(title))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(minWidth: subscriptionDetailLabelMinWidth, alignment: .leading)
                .layoutPriority(1)

            Spacer(minLength: subscriptionDetailSpacerMinLength)

            #if os(macOS)
            SubscriptionSourceMacTextField(
                text: $text,
                accessibilityLabel: title,
                onCommit: onCommit
            )
            .frame(width: subscriptionDetailTextFieldWidth, height: 22, alignment: .center)
            #else
            TextField("", text: $text)
                .settingsPlainInput()
                .multilineTextAlignment(.trailing)
                .focused($isFocused)
                .frame(width: subscriptionDetailTextFieldWidth)
                .contentShape(Rectangle())
                .accessibilityLabel(Text(LocalizedStringKey(title)))
                .onTapGesture {
                    isFocused = true
                }
                .onSubmit(onCommit)
            #endif
        }
    }
}

private struct UnavailableDetailView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Данные недоступны")
                .font(.headline)
            Text("Объект был удален или обновлен.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#if os(macOS)
private struct SubscriptionSourceMacTextField: NSViewRepresentable {
    @Binding var text: String
    let accessibilityLabel: String
    let onCommit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onCommit: onCommit)
    }

    func makeNSView(context: Context) -> NSTextField {
        let textField = SubscriptionSourceNoFocusRingTextField()
        textField.delegate = context.coordinator
        textField.stringValue = text
        textField.isBordered = false
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.alignment = .right
        textField.font = .systemFont(ofSize: NSFont.systemFontSize)
        textField.lineBreakMode = .byTruncatingHead
        textField.cell = SubscriptionSourceCenteredTextFieldCell(textCell: text)
        textField.cell?.usesSingleLineMode = true
        textField.cell?.wraps = false
        textField.cell?.isScrollable = true
        textField.cell?.lineBreakMode = .byTruncatingHead
        textField.isEditable = true
        textField.isSelectable = true
        textField.textColor = .labelColor
        textField.setAccessibilityLabel(accessibilityLabel)
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return textField
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onCommit = onCommit

        if nsView.stringValue != text {
            nsView.stringValue = text
        }

        nsView.alignment = .right
        nsView.focusRingType = .none
        nsView.font = .systemFont(ofSize: NSFont.systemFontSize)
        nsView.textColor = .labelColor
        nsView.setAccessibilityLabel(accessibilityLabel)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var onCommit: () -> Void

        init(text: Binding<String>, onCommit: @escaping () -> Void) {
            self.text = text
            self.onCommit = onCommit
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else {
                return
            }

            text.wrappedValue = textField.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else {
                return
            }

            text.wrappedValue = textField.stringValue
            onCommit()
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else {
                return false
            }

            if let textField = control as? NSTextField {
                text.wrappedValue = textField.stringValue
            }
            control.window?.makeFirstResponder(nil)
            onCommit()
            return true
        }
    }
}

private final class SubscriptionSourceNoFocusRingTextField: NSTextField {
    override var focusRingType: NSFocusRingType {
        get { .none }
        set {}
    }

    override var focusRingMaskBounds: NSRect {
        .zero
    }

    override func drawFocusRingMask() {}
}

private final class SubscriptionSourceCenteredTextFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        centeredRect(forBounds: rect)
    }

    override func edit(
        withFrame cellFrame: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        event: NSEvent?
    ) {
        super.edit(
            withFrame: centeredRect(forBounds: cellFrame),
            in: controlView,
            editor: textObj,
            delegate: delegate,
            event: event
        )
    }

    override func select(
        withFrame cellFrame: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        start selStart: Int,
        length selLength: Int
    ) {
        super.select(
            withFrame: centeredRect(forBounds: cellFrame),
            in: controlView,
            editor: textObj,
            delegate: delegate,
            start: selStart,
            length: selLength
        )
    }

    private func centeredRect(forBounds rect: NSRect) -> NSRect {
        var drawingRect = super.drawingRect(forBounds: rect)
        let textHeight = cellSize(forBounds: rect).height
        let verticalOffset = max(0, (drawingRect.height - textHeight) / 2)
        drawingRect.origin.y += verticalOffset
        drawingRect.size.height -= verticalOffset * 2
        return drawingRect
    }
}
#endif

private struct LogScreen: View {
    @Environment(\.dismiss) private var dismiss
    let logs: [String]
    let onClear: () -> Void

    var body: some View {
        NavigationStack {
            LogView(logs: logs, onClear: onClear)
                .navigationTitle("Журнал")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Готово") {
                            dismiss()
                        }
                    }
                }
        }
        #if os(macOS)
        .frame(width: 460, height: 500)
        #endif
    }
}

private struct SubscriptionMarker: View {
    let metadata: SubscriptionMetadata?
    var fallbackSystemImage = "folder"
    var isSelected = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(markerColor.opacity(isSelected ? 0.28 : 0.18))
                .frame(width: 28, height: 28)
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(markerColor, lineWidth: 1.5)
                    }
                }

            if let icon = metadata?.nodeIcon ?? metadata?.icon, !icon.isEmpty {
                Text(icon)
                    .font(.caption)
                    .lineLimit(1)
            } else {
                Image(systemName: fallbackSystemImage)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(markerColor)
            }
        }
        .frame(width: 28, height: 28)
    }

    private var markerColor: Color {
        Color(hex: metadata?.nodeColor ?? metadata?.color) ?? .accentColor
    }
}

private struct StatusBadge: View {
    let status: ClientStatus

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch status {
        case .failed(let message):
            message.isEmpty ? AppLocalization.string("Error") : AppLocalization.format("Error: %@", message)
        default:
            status.localizedTitle
        }
    }

    private var color: Color {
        switch status {
        case .stopped: .secondary
        case .starting, .stopping: .orange
        case .ready: .green
        case .failed: .red
        }
    }
}

private func pluralizedServers(_ count: Int) -> String {
    guard AppLocalization.localeIdentifier == "ru_RU" else {
        return count == 1 ? "1 server" : "\(count) servers"
    }

    let mod10 = count % 10
    let mod100 = count % 100
    let word: String
    if mod10 == 1 && mod100 != 11 {
        word = "сервер"
    } else if (2...4).contains(mod10) && !(12...14).contains(mod100) {
        word = "сервера"
    } else {
        word = "серверов"
    }
    return "\(count) \(word)"
}

private extension ConnectionProfile {
    var displayName: String {
        name.isEmpty ? AppLocalization.string("Untitled") : name
    }

    var listDetail: String {
        var values: [String] = []
        if let ip = subscription?.nodeIP {
            values.append(ip)
        }
        values.append("\(carrier.title) · \(transport.title)")
        if let available = subscription?.nodeAvailable {
            values.append(available)
        }
        return values.joined(separator: " · ")
    }
}

private extension ClientStatus {
    var localizedTitle: String {
        switch self {
        case .stopped: AppLocalization.string("Disconnected")
        case .starting: AppLocalization.string("Connecting...")
        case .ready: AppLocalization.string("Connected")
        case .stopping: AppLocalization.string("Disconnecting...")
        case .failed: AppLocalization.string("Error")
        }
    }
}

private extension View {
    @ViewBuilder
    func logPresentation<Content: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        #if os(iOS)
        self.fullScreenCover(isPresented: isPresented, content: content)
        #else
        self.sheet(isPresented: isPresented, content: content)
        #endif
    }

    @ViewBuilder
    func settingsPlainInput() -> some View {
        #if os(iOS)
        self
            .textFieldStyle(.plain)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        self
            .textFieldStyle(.plain)
        #endif
    }
}

private extension Color {
    init?(hex: String?) {
        guard var value = hex?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        if value.hasPrefix("#") {
            value.removeFirst()
        }

        guard value.count == 6, let raw = Int(value, radix: 16) else {
            return nil
        }

        self.init(
            red: Double((raw >> 16) & 0xFF) / 255.0,
            green: Double((raw >> 8) & 0xFF) / 255.0,
            blue: Double(raw & 0xFF) / 255.0
        )
    }
}
