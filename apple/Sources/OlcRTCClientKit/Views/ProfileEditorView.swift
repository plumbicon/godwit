import SwiftUI

#if os(macOS)
import AppKit
#endif

private let profileEditorValueColumnWidth: CGFloat = 200
#if os(iOS)
private let profileEditorTextFieldWidth: CGFloat = 148
private let profileEditorNumberFieldWidth: CGFloat = 56
private let profileEditorLabelMinWidth: CGFloat = 0
private let profileEditorRowSpacing: CGFloat = 8
private let profileEditorSpacerMinLength: CGFloat = 8
#else
private let profileEditorTextFieldWidth: CGFloat = profileEditorValueColumnWidth
private let profileEditorNumberFieldWidth: CGFloat = 64
private let profileEditorLabelMinWidth: CGFloat = 170
private let profileEditorRowSpacing: CGFloat = 12
private let profileEditorSpacerMinLength: CGFloat = 16
#endif
private let videoCodecOptions = ["qrcode", "tile"]
private let videoHardwareOptions = ["none", "nvenc"]
private let videoQRRecoveryOptions = ["low", "medium", "high", "highest"]

public struct ProfileEditorView: View {
    @Binding var profile: ConnectionProfile
    @Binding var useSystemProxy: Bool
    @Binding var selectedNetworkService: String
    @State private var isAdvancedExpanded = false

    let networkServices: [String]
    let validationMessage: String?
    let onCommit: () -> Void

    public init(
        profile: Binding<ConnectionProfile>,
        useSystemProxy: Binding<Bool>,
        selectedNetworkService: Binding<String>,
        networkServices: [String],
        validationMessage: String?,
        startsAdvancedExpanded: Bool = false,
        onCommit: @escaping () -> Void
    ) {
        _profile = profile
        _useSystemProxy = useSystemProxy
        _selectedNetworkService = selectedNetworkService
        _isAdvancedExpanded = State(initialValue: startsAdvancedExpanded)
        self.networkServices = networkServices
        self.validationMessage = validationMessage
        self.onCommit = onCommit
    }

    public var body: some View {
        Form {
            if let subscription = profile.subscription {
                Section("Подписка") {
                    LabeledContent("Название", value: subscription.name)

                    if let sourceURL = subscription.sourceURL {
                        LabeledContent("Источник") {
                            Text(sourceURL)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                    }

                    if let available = subscription.available {
                        LabeledContent("Доступно", value: available)
                    }

                    if let used = subscription.used {
                        LabeledContent("Использовано", value: used)
                    }

                    if let nodeIP = subscription.nodeIP {
                        LabeledContent("IP узла", value: nodeIP)
                    }

                    if let nodeComment = subscription.nodeComment {
                        LabeledContent("Комментарий") {
                            Text(nodeComment)
                                .lineLimit(2)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
            }

            if let validationMessage {
                Section {
                    Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            Section("Профиль") {
                ProfileNameRow(name: $profile.name, onCommit: onCommit)

                ProfilePickerRow(title: "Провайдер", selection: $profile.carrier) { carrier in
                    carrier.title
                }

                ProfilePickerRow(title: "Транспорт", selection: $profile.transport) { transport in
                    transport.title
                }
            }

            Section {
                connectionHeaderRow

                if isAdvancedExpanded {
                    ConnectionTextRow(
                        title: profile.carrier == .jitsi ? "Room URL" : "Room ID",
                        text: $profile.roomID,
                        onCommit: onCommit
                    )

                    ConnectionSecureRow(title: "Ключ", text: $profile.keyHex, onCommit: onCommit)

                    switch profile.transport {
                    case .vp8channel:
                        ConnectionNumberRow(title: "FPS", value: $profile.vp8FPS, range: 1...120, showsStepper: true)
                        ConnectionNumberRow(
                            title: "Размер пакета",
                            value: $profile.vp8BatchSize,
                            range: 1...128,
                            showsStepper: true
                        )

                    case .seichannel:
                        ConnectionNumberRow(title: "FPS", value: $profile.seiFPS, range: 1...120, showsStepper: true)
                        ConnectionNumberRow(
                            title: "Размер пакета",
                            value: $profile.seiBatchSize,
                            range: 1...128,
                            showsStepper: true
                        )
                        ConnectionNumberRow(
                            title: "Размер фрагмента",
                            value: $profile.seiFragmentSize,
                            range: 64...4_096
                        )
                        ConnectionAckTimeoutRow(
                            title: "ACK таймаут",
                            value: $profile.seiAckTimeoutMillis,
                            range: 100...10_000
                        )

                    case .videochannel:
                        ConnectionPickerRow(title: "Кодек", selection: $profile.videoCodec, options: videoCodecOptions)
                        ConnectionNumberRow(title: "Ширина", value: $profile.videoWidth, range: 1...7_680)
                        ConnectionNumberRow(title: "Высота", value: $profile.videoHeight, range: 1...4_320)
                        ConnectionNumberRow(title: "FPS", value: $profile.videoFPS, range: 1...120, showsStepper: true)
                        ConnectionTextRow(title: "Битрейт", text: $profile.videoBitrate, onCommit: onCommit)
                        ConnectionPickerRow(
                            title: "Ускорение",
                            selection: $profile.videoHardwareAcceleration,
                            options: videoHardwareOptions
                        )
                        ConnectionPickerRow(
                            title: "QR коррекция",
                            selection: $profile.videoQRRecovery,
                            options: videoQRRecoveryOptions
                        )
                        ConnectionNumberRow(title: "QR фрагмент", value: $profile.videoQRSize, range: 0...65_535)

                        if profile.videoCodec == "tile" {
                            ConnectionNumberRow(title: "Размер тайла", value: $profile.videoTileModule, range: 1...270)
                            ConnectionNumberRow(title: "RS паритет, %", value: $profile.videoTileRS, range: 0...200)
                        }

                    case .datachannel:
                        EmptyView()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear(perform: onCommit)
    }

    private var connectionHeaderRow: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                isAdvancedExpanded.toggle()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isAdvancedExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 14)

                Text("Подключение")
                    .font(.headline)

                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ProfileNameRow: View {
    @Binding var name: String
    let onCommit: () -> Void

    var body: some View {
        TextField("Название профиля", text: $name)
            .olcNativeInput()
            .onSubmit(onCommit)
    }
}

private struct ProfilePickerRow<Option>: View where Option: CaseIterable & Hashable & Identifiable {
    let title: String
    @Binding var selection: Option
    let optionTitle: (Option) -> String

    var body: some View {
        HStack(alignment: .center, spacing: profileEditorRowSpacing) {
            Text(LocalizedStringKey(title))

            Spacer(minLength: profileEditorSpacerMinLength)

            Picker("", selection: $selection) {
                ForEach(Array(Option.allCases)) { option in
                    Text(optionTitle(option)).tag(option)
                }
            }
            .labelsHidden()
            .frame(maxWidth: profileEditorValueColumnWidth, alignment: .trailing)
        }
    }
}

private struct ConnectionAckTimeoutRow: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    @FocusState private var isFocused: Bool

    private var clampedValue: Binding<Int> {
        Binding(
            get: { value },
            set: { newValue in
                value = min(max(newValue, range.lowerBound), range.upperBound)
            }
        )
    }

    private var textValue: Binding<String> {
        Binding(
            get: { "\(value)" },
            set: { newValue in
                let digits = newValue.filter(\.isNumber)
                guard let parsedValue = Int(digits) else {
                    return
                }
                value = min(max(parsedValue, range.lowerBound), range.upperBound)
            }
        )
    }

    var body: some View {
        HStack(alignment: .center, spacing: profileEditorRowSpacing) {
            Text(LocalizedStringKey(title))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(minWidth: profileEditorLabelMinWidth, alignment: .leading)
                .layoutPriority(1)

            Spacer(minLength: profileEditorSpacerMinLength)

            TextField("", text: textValue)
                .olcNativeInput()
                .multilineTextAlignment(.trailing)
                .font(.body.monospacedDigit())
                .focused($isFocused)
                .frame(width: 88)
                .contentShape(Rectangle())
                .accessibilityLabel(Text(LocalizedStringKey(title)))
                .onTapGesture {
                    isFocused = true
                }
                .frame(alignment: .trailing)
        }
    }
}

private struct ConnectionPickerRow: View {
    let title: String
    @Binding var selection: String
    let options: [String]

    var body: some View {
        HStack(alignment: .center, spacing: profileEditorRowSpacing) {
            Text(LocalizedStringKey(title))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(minWidth: profileEditorLabelMinWidth, alignment: .leading)
                .layoutPriority(1)

            Spacer(minLength: profileEditorSpacerMinLength)

            Picker("", selection: $selection) {
                ForEach(options, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(maxWidth: profileEditorValueColumnWidth, alignment: .trailing)
        }
    }
}

private struct ConnectionTextRow: View {
    let title: String
    @Binding var text: String
    let onCommit: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .center, spacing: profileEditorRowSpacing) {
            Text(LocalizedStringKey(title))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(minWidth: profileEditorLabelMinWidth, alignment: .leading)
                .layoutPriority(1)

            Spacer(minLength: profileEditorSpacerMinLength)

            #if os(macOS)
            MacConnectionTextField(
                text: $text,
                accessibilityLabel: title,
                onCommit: onCommit
            )
            .frame(width: profileEditorTextFieldWidth, height: 22, alignment: .center)
            #else
            TextField("", text: $text)
                .olcNativeInput()
                .multilineTextAlignment(.trailing)
                .focused($isFocused)
                .frame(width: profileEditorTextFieldWidth)
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

private struct ConnectionSecureRow: View {
    let title: String
    @Binding var text: String
    let onCommit: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .center, spacing: profileEditorRowSpacing) {
            Text(LocalizedStringKey(title))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(minWidth: profileEditorLabelMinWidth, alignment: .leading)
                .layoutPriority(1)

            Spacer(minLength: profileEditorSpacerMinLength)

            SecureField("", text: $text)
                .olcNativeInput()
                .textContentType(.oneTimeCode)
                .multilineTextAlignment(.trailing)
                .focused($isFocused)
                .frame(width: profileEditorTextFieldWidth)
                .contentShape(Rectangle())
                .accessibilityLabel(Text(LocalizedStringKey(title)))
                .onTapGesture {
                    isFocused = true
                }
                .onSubmit(onCommit)
        }
    }
}

private struct ConnectionNumberRow: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var suffix = ""
    var showsStepper = false
    var step = 1
    @FocusState private var isFocused: Bool

    private var clampedValue: Binding<Int> {
        Binding(
            get: { value },
            set: { newValue in
                value = min(max(newValue, range.lowerBound), range.upperBound)
            }
        )
    }

    var body: some View {
        HStack(alignment: .center, spacing: profileEditorRowSpacing) {
            Text(LocalizedStringKey(title))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(minWidth: profileEditorLabelMinWidth, alignment: .leading)
                .layoutPriority(1)

            Spacer(minLength: profileEditorSpacerMinLength)

            HStack(alignment: .center, spacing: 4) {
                TextField("", value: clampedValue, format: .number)
                    .olcNativeInput()
                    .multilineTextAlignment(.trailing)
                    .focused($isFocused)
                    .frame(width: profileEditorNumberFieldWidth)
                    .contentShape(Rectangle())
                    .accessibilityLabel(Text(LocalizedStringKey(title)))
                    .onTapGesture {
                        isFocused = true
                    }

                if !suffix.isEmpty {
                    Text(suffix)
                        .foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .leading)
                }

                if showsStepper {
                    Stepper("", value: clampedValue, in: range, step: step)
                        .labelsHidden()
                        .fixedSize()
                        .controlSize(.small)
                }
            }
            .frame(alignment: .trailing)
        }
    }
}

private extension View {
    @ViewBuilder
    func olcNativeInput() -> some View {
        #if os(iOS)
        self
            .textFieldStyle(.plain)
            .lineLimit(1)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        self
            .textFieldStyle(.plain)
            .lineLimit(1)
        #endif
    }
}

#if os(macOS)
private struct MacConnectionTextField: NSViewRepresentable {
    @Binding var text: String
    let accessibilityLabel: String
    let onCommit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onCommit: onCommit)
    }

    func makeNSView(context: Context) -> NSTextField {
        let textField = NoFocusRingTextField()
        textField.delegate = context.coordinator
        textField.stringValue = text
        textField.isBordered = false
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.alignment = .right
        textField.font = .systemFont(ofSize: NSFont.systemFontSize)
        textField.lineBreakMode = .byTruncatingHead
        textField.cell = CenteredSingleLineTextFieldCell(textCell: text)
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

private final class NoFocusRingTextField: NSTextField {
    override var focusRingType: NSFocusRingType {
        get { .none }
        set {}
    }

    override var focusRingMaskBounds: NSRect {
        .zero
    }

    override func drawFocusRingMask() {}
}

private final class CenteredSingleLineTextFieldCell: NSTextFieldCell {
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
