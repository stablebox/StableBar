import AppKit

/// What a widget shows: its text and icon, and the fields its layout blocks read, which add
/// `text` and `icon` to the output's own fields.
struct WidgetLabel: Equatable, Sendable {
    var text: String
    var icon: String?
    var fields: [String: String]
}

extension WidgetConfiguration {
    /// This widget's label: a text widget's text, a clock's time at `date`, with its format's date and time parts
    /// as the `date` and `time` fields, the frontmost app's name (`activeApp`, else Desktop), or its script or
    /// provider output. The bar, the More widgets menu and Diagnostics all read it here. Workspaces and spacers have
    /// no text.
    func label(output: ScriptOutput?, activeApp: String?, date: Date) -> WidgetLabel {
        var icon = self.icon
        var fields = output?.fields ?? [:]
        let text: String
        switch content {
        case let .text(value):
            text = value
        case let .clock(format):
            let formatter = DateFormatter()
            formatter.dateFormat = format
            formatter.timeZone = timeZone.flatMap(TimeZone.init(identifier:)) ?? .autoupdatingCurrent
            text = formatter.string(from: date)
            let parts = Self.clockFormatParts(format)
            formatter.dateFormat = parts.date
            fields["date"] = formatter.string(from: date)
            formatter.dateFormat = parts.time
            fields["time"] = formatter.string(from: date)
        case .activeApp:
            text = activeApp ?? "Desktop"
        case .controlCenter, .menuBarItems:
            text = ""
            icon = icon ?? content.symbol
        case .quickToggles:
            text = output?.text ?? ""
            icon = icon ?? content.symbol
        case .script, .provider:
            text = output?.text ?? "…"
            icon = output?.icon ?? icon
        case .stableBar:
            text = ""
        case .workspaces, .appMenu, .appleMenu, .spacer:
            return WidgetLabel(text: "", icon: icon, fields: fields)
        }
        fields["text"] = text
        fields["icon"] = icon ?? ""
        return WidgetLabel(text: text, icon: icon, fields: fields)
    }

    /// `format`'s date and time patterns. The time runs from its first hour, minute, second, day-period or zone letter
    /// to its last, with the literal text that touches its end, such as `分`; the date is the rest, without the spaces between it and the time and the quoted text there that
    /// touches the time or stands apart from the date, such as `'T'` or ` 'at' `. Quoted text that touches the date, such
    /// as `'日'`, is part of it.
    private static func clockFormatParts(_ format: String) -> (date: String, time: String) {
        var quote: String.Index?
        var quotes: [Range<String.Index>] = []
        var time: Range<String.Index>?
        for index in format.indices {
            if format[index] == "'" {
                if let start = quote {
                    // `''` inside quoted text is an apostrophe, so quotes that touch are one.
                    if let last = quotes.last, last.upperBound == start {
                        quotes[quotes.count - 1] = last.lowerBound..<format.index(after: index)
                    } else {
                        quotes.append(start..<format.index(after: index))
                    }
                }
                quote = quote == nil ? index : nil
            } else if quote == nil, "abBhHkKmsSAzZOvVXx".contains(format[index]) {
                time = (time?.lowerBound ?? index)..<format.index(after: index)
            }
        }
        guard var time else { return (format, "") }
        var suffix = time.upperBound
        while suffix < format.endIndex, !format[suffix].isWhitespace, !(format[suffix].isASCII && format[suffix].isLetter) {
            if let quoted = quotes.first(where: { $0.lowerBound == suffix }) {
                if format[format.index(after: quoted.lowerBound)].isWhitespace { break }
                suffix = quoted.upperBound
            } else {
                suffix = format.index(after: suffix)
            }
        }
        time = time.lowerBound..<suffix
        var end = time.lowerBound
        while end > format.startIndex {
            if format[format.index(before: end)].isWhitespace {
                end = format.index(before: end)
            } else if let quoted = quotes.first(where: { $0.upperBound == end }), end == time.lowerBound
                        || quoted.lowerBound == format.startIndex || format[format.index(before: quoted.lowerBound)].isWhitespace {
                end = quoted.lowerBound
            } else {
                break
            }
        }
        var start = time.upperBound
        while start < format.endIndex {
            if format[start].isWhitespace {
                start = format.index(after: start)
            } else if let quoted = quotes.first(where: { $0.lowerBound == start }), start == time.upperBound
                        || quoted.upperBound == format.endIndex || format[quoted.upperBound].isWhitespace {
                start = quoted.upperBound
            } else {
                break
            }
        }
        let date = [format[..<end], format[start...]].filter { !$0.isEmpty }.joined(separator: " ")
        return (date, String(format[time]))
    }
}

extension BarStore {
    /// `widget`'s label from its current output. Only active-app widgets read the frontmost app, so
    /// switching apps redraws no other widget.
    func label(for widget: WidgetConfiguration, date: Date = .now) -> WidgetLabel {
        let output = if case .quickToggles = widget.content { QuickToggles.shared.keepAwake.barOutput(at: date) }
            else { widgetScripts.scripts[widget.id]?.output }
        return widget.label(output: output, activeApp: widget.content == .activeApp ? appWatcher.activeApp?.localizedName : nil, date: date)
    }
}

extension WidgetConfiguration {
    /// The colors of macOS's own privacy indicators, which the privacy widget lights its icons with.
    private static let microphoneColor = HexColor(light: 0xff9500ff, dark: 0xff9f0aff)
    private static let cameraColor = HexColor(light: 0x34c759ff, dark: 0x30d158ff)

    /// The blocks a widget without `layout` draws, matching the look built-in widgets had before
    /// they were drawn through blocks: its icon and text in a row at least a line of text tall, after
    /// a 40 × 16 graph for output with a `value`, or after the app's icon for the active app.
    /// `providerType` is the type of the widget's provider, else its name is. Battery draws only its
    /// battery, its percentage left to the tooltip, or its icon and text on a Mac without one; sound
    /// (`audio`) draws its icon, with the volume only while a change shows it; privacy its microphone and camera, lit while
    /// in use and dimmed otherwise, or with `hideWhenIdle` only those in use. `appIcon` says whether
    /// the frontmost app has one. Workspaces, spacers and scripts without output have none.
    func defaultLayout(_ label: WidgetLabel, output: ScriptOutput?, appIcon: Bool, providerType: String? = nil) -> PopupBlock? {
        let icon = label.icon.map { _ in PopupBlock(content: .symbol(name: "", source: "icon")) }
        let text = PopupBlock(content: .field("text"), hideWhenEmpty: "text")
        switch content {
        case .quickToggles:
            // While Keep awake is on, a cup and the time it has left.
            return PopupBlock(content: .row([icon,
                                             PopupBlock(content: .symbol(name: QuickTile.keepAwake.symbol, source: nil), hideWhenEmpty: "keepAwake"),
                                             PopupBlock(content: .field("text"), hideWhenEmpty: "text")].compactMap { $0 }),
                              keepsLineHeight: true)
        case .text, .controlCenter, .menuBarItems:
            return PopupBlock(content: .row([icon, text].compactMap { $0 }), keepsLineHeight: true)
        case .clock:
            return PopupBlock(content: .row([icon, PopupBlock(content: .field("text"), hideWhenEmpty: "text")].compactMap { $0 }),
                              keepsLineHeight: true)
        case .activeApp:
            let app = appIcon ? PopupBlock(content: .appIcon) : nil
            return PopupBlock(content: .row([app, PopupBlock(content: .field("text"), monospacedDigits: false)].compactMap { $0 }))
        case .provider where (providerType ?? providerName) == DataSourceType.audio.name:
            guard output != nil else { return nil }
            let field = AudioMonitor.changedVolumeField
            let volume = PopupBlock(content: .field(field), hideWhenEmpty: field, transition: transition == nil ? .numeric : nil)
            let speaker = label.icon.map { _ in PopupBlock(content: .symbol(name: "", source: "icon"), widestSymbol: AudioMonitor.widestIcon) }
            return PopupBlock(content: .row([speaker, volume].compactMap { $0 }), keepsLineHeight: true)
        case .provider where (providerType ?? providerName) == DataSourceType.privacy.name:
            guard let output else { return nil }
            let muted = output.fields?["muted"] == "true"
            let icons = [("microphone", muted ? "mic.slash" : "mic", Self.microphoneColor), ("camera", "video", Self.cameraColor)]
                .compactMap { field, symbol, color -> PopupBlock? in
                    let inUse = output.fields?[field] == "true"
                    guard inUse || !hideWhenIdle else { return nil }
                    return PopupBlock(content: .symbol(name: symbol, source: nil), style: inUse ? WidgetStyle(foreground: color) : WidgetStyle(opacity: 0.5))
                }
            return PopupBlock(content: .row(icons), keepsLineHeight: true)
        case .provider where (providerType ?? providerName) == DataSourceType.battery.name && output?.fields?["present"] != "false":
            guard output != nil else { return nil }
            return PopupBlock(content: .row([PopupBlock(content: .battery(source: "percent"))]), keepsLineHeight: true)
        case .provider where (providerType ?? providerName) == "calendar" && details:
            return PopupBlock(content: .row([
                PopupBlock(content: .symbol(name: "calendar", source: nil)),
                PopupBlock(content: .field("text"), style: WidgetStyle(maxWidth: 180), monospacedDigits: false),
                PopupBlock(content: .field("minutes"), hideWhenEmpty: "minutes"),
                PopupBlock(content: .text("min"), hideWhenEmpty: "minutes")
            ]), keepsLineHeight: true)
        case .script, .provider:
            guard let output else { return nil }
            let type = providerType ?? providerName
            let graph = output.value == nil || type == "battery" ? nil
                : PopupBlock(content: .graph(height: 16, source: nil, lineWidth: 1.2), style: WidgetStyle(width: 40))
            let label = PopupBlock(content: .row([icon, text].compactMap { $0 }), keepsLineHeight: true)
            return PopupBlock(content: .row([graph, label].compactMap { $0 }))
        case .workspaces, .appMenu, .appleMenu, .stableBar, .spacer:
            return nil
        }
    }
}

extension WidgetLabel {
    /// This label with `fields` shown over its own. A `text` or `icon` field replaces the text or
    /// icon; an empty `icon` hides it.
    func overlaid(by fields: [String: String]?) -> WidgetLabel {
        guard let fields else { return self }
        var label = self
        label.fields.merge(fields) { $1 }
        if let text = fields["text"] { label.text = text }
        if let icon = fields["icon"] { label.icon = icon.isEmpty ? nil : icon }
        return label
    }
}
