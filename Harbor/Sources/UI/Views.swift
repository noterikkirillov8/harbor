import SwiftUI

enum Layout {
    static let width: CGFloat = 440
    static let rowHeight: CGFloat = 56
    static let maxList: CGFloat = 448        // eight rows, then the list scrolls
    static let sideColumn: CGFloat = 84      // activity strip + memory, or the three hover keys
    static let sectionLabel: CGFloat = 32
    static let emptyBoard: CGFloat = 196
    static let confirmBar: CGFloat = 72
    static let banner: CGFloat = 76
    /// QA: stop animations so a frame of a moment can be captured at a fixed progress.
    nonisolated(unsafe) static var frozen = false
}

struct Entrance: ViewModifier {
    var shown: Bool
    @Environment(\.accessibilityReduceMotion) private var reduce
    func body(content: Content) -> some View {
        if reduce { content.opacity(shown ? 1 : 0).animation(KitMotion.soft, value: shown) } else { content.kitPanelEntrance(shown) }
    }
}

struct HarborView: View {
    let model: HarborModel
    var forceHover: Int32?          // QA: show the hover keys of one row
    var onHeight: (CGFloat) -> Void = { _ in }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        KitPanel(title: "Harbor", width: Layout.width) {
            header
        } content: {
            content
        } footer: {
            footer
        }
        .kitAccent(Color(hex: 0x5BD08A))
        .overlay(alignment: .top) { PowerLine(trigger: model.pulse, preview: model.pulsePreview).padding(.top, 52) }
        .modifier(Entrance(shown: model.shown))
        .frame(maxHeight: .infinity, alignment: .top)
        .onChange(of: targetHeight, initial: true) { _, h in onHeight(h) }
    }

    /// Height of the whole panel for the current state. The NSPanel animates to this once, while the
    /// content animates inside it; `-qa` checks it against the real layout.
    var targetHeight: CGFloat {
        let showOthers = model.showOther && !model.other.isEmpty
        var body: CGFloat
        if !model.hasData { body = 3 * Layout.rowHeight }
        else {
            body = model.dev.isEmpty ? Layout.emptyBoard : 0
            let rows = model.dev.count + (showOthers ? model.other.count : 0)
            body += min(CGFloat(rows) * Layout.rowHeight + (showOthers ? Layout.sectionLabel : 0), Layout.maxList)
        }
        if model.hasData && model.banner != nil { body += Layout.banner }
        let footer = model.confirmAll || model.confirmIdle ? Layout.confirmBar : 28
        return 52 + 1 + body + 1 + 24 + footer + 0
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: KitSpace.m) {
            HStack(spacing: 6) {
                KitLed(on: !model.dev.isEmpty)
                if model.stoppingCount > 0 {
                    Text("Stopping \(model.stoppingCount)").font(KitFont.key).foregroundStyle(KitColor.red).monospacedDigit()
                } else {
                    Text("\(model.counted ? model.serverCount : 0) running").font(KitFont.key).foregroundStyle(KitColor.text2).monospacedDigit()
                        .kitRollingNumber(model.counted ? model.serverCount : 0)
                }
            }
            if model.dev.contains(where: { $0.container == nil }) {
                Text(Fmt.memory(model.counted ? model.devMemory : 0))
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(KitColor.text2)
                    .kitRollingNumber(model.counted ? model.devMemory : 0)
            }
        }
    }

    // MARK: list

    @ViewBuilder private var content: some View {
        if !model.hasData {
            Skeleton()
        } else {
            let showOthers = model.showOther && !model.other.isEmpty
            VStack(spacing: 0) {
                if let c = model.banner { PortBanner(model: model, conflict: c).transition(.kitBar) }
                if model.dev.isEmpty { EmptyBoard(others: model.other.count).frame(height: Layout.emptyBoard) }
                let rows = model.dev.count + (showOthers ? model.other.count : 0)
                let height = CGFloat(rows) * Layout.rowHeight + (showOthers ? Layout.sectionLabel : 0)
                if rows > 0 {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(model.dev.enumerated()), id: \.element.id) { i, row in
                                RowView(model: model, row: row, isOther: false, index: i, forced: forceHover == row.pid, last: !showOthers && row.id == model.dev.last?.id)
                                    .transition(rowTransition)
                            }
                            if showOthers {
                                sectionLabel
                                ForEach(Array(model.other.enumerated()), id: \.element.id) { i, row in
                                    RowView(model: model, row: row, isOther: true, index: model.dev.count + i, forced: forceHover == row.pid, last: row.id == model.other.last?.id)
                                        .transition(rowTransition)
                                }
                            }
                        }
                    }
                    .scrollIndicators(.never)
                    .frame(height: min(height, Layout.maxList))
                }
            }
        }
    }

    private var rowTransition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(y: 8)), removal: AnyTransition(Collapse()))
    }

    private var sectionLabel: some View {
        HStack {
            Text("Other apps").font(KitFont.header).foregroundStyle(KitColor.text2)
            Spacer()
        }
        .padding(.horizontal, KitSpace.l)
        .frame(height: Layout.sectionLabel)
        .overlay(alignment: .bottom) { KitDivider() }
    }

    // MARK: footer

    @ViewBuilder private var footer: some View {
        if model.confirmAll || model.confirmIdle {
            let idle = model.confirmIdle
            let rows = idle ? model.idleRows : model.dev
            let servers = Set(rows.map(\.ownerKey)).count
            VStack(alignment: .leading, spacing: KitSpace.m) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Stop \(servers) \(idle ? "idle " : "")dev server\(servers == 1 ? "" : "s")?")
                        .font(KitFont.bodyMedium).foregroundStyle(KitColor.text)
                    Text(rows.prefix(8).map { String($0.port) }.joined(separator: ", ") + (rows.count > 8 ? ", and \(rows.count - 8) more" : ""))
                        .font(.system(size: 11).monospacedDigit()).foregroundStyle(KitColor.text2).lineLimit(1)
                }
                HStack(spacing: KitSpace.s) {
                    Button("Stop \(servers)") { idle ? model.stopIdle() : model.stopAllDev() }.buttonStyle(.kitDestructive)
                    Button("Cancel") { withAnimation(KitMotion.list) { model.confirmAll = false; model.confirmIdle = false } }.buttonStyle(.kitSecondary)
                    Spacer()
                }
            }
            .frame(height: Layout.confirmBar, alignment: .top)
            .transition(.kitBar)
        } else {
            HStack(spacing: KitSpace.s) {
                if !model.other.isEmpty {
                    KeyToggle(title: "Other apps", count: model.other.count, isOn: Binding(get: { model.showOther }, set: { model.showOther = $0 }))
                }
                Spacer()
                if !model.idleRows.isEmpty {
                    Button("Stop idle (\(Set(model.idleRows.map(\.ownerKey)).count))") { withAnimation(KitMotion.list) { model.confirmIdle = true } }
                        .buttonStyle(.kitSecondary)
                }
                Button("Stop all") { withAnimation(KitMotion.list) { model.confirmAll = true } }
                    .buttonStyle(.kitSecondary).disabled(model.dev.isEmpty)
                MoreMenu(model: model)
            }
        }
    }
}

/// First open of a session: the hairline under the title lights in the accent from the centre outward,
/// then settles back to the normal line colour.
struct PowerLine: View {
    let trigger: Int
    var preview: Double? = nil
    @State private var width = 0.0
    @State private var alpha = 0.0
    @Environment(\.kitAccent) private var accent

    var body: some View {
        Rectangle().fill(accent).frame(height: 1)
            .scaleEffect(x: preview ?? width, y: 1)
            .opacity(preview == nil ? alpha : 1)
            .allowsHitTesting(false)
            .onChange(of: trigger) { _, _ in
                width = 0; alpha = 1
                withAnimation(.easeOut(duration: 0.25)) { width = 1 }
                Task { try? await Task.sleep(for: .milliseconds(250)); withAnimation(KitMotion.soft) { alpha = 0 } }
            }
    }
}

/// Row removal: height collapses and the row fades (0.22 s). Rows have a fixed height, so this is exact.
struct Collapse: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        let t = phase == .didDisappear ? 1.0 : 0.0
        content
            .frame(height: Layout.rowHeight * (1 - t), alignment: .top)
            .clipped()
            .opacity(1 - t)
    }
}

// MARK: - Row

struct RowView: View {
    let model: HarborModel
    let row: PortRow
    let isOther: Bool
    var forced = false
    var index = 0
    var last = false
    @State private var hover = false
    @State private var drain: Double
    @State private var ledOn = true
    @State private var copied = false
    @Environment(\.kitAccent) private var accent

    init(model: HarborModel, row: PortRow, isOther: Bool, index: Int = 0, forced: Bool = false, last: Bool = false) {
        self.model = model; self.row = row; self.isOther = isOther; self.index = index; self.forced = forced; self.last = last
        switch model.states[row.ownerKey] {
        case .stopping(let since): _drain = State(initialValue: min(1, Date().timeIntervalSince(since) / 3))
        case .gone, .stuck: _drain = State(initialValue: 1)
        case nil: _drain = State(initialValue: 0)
        }
    }

    private var state: StopState? { model.states[row.ownerKey] }
    private var stat: Stat? { model.stats[row.pid] }
    private var confirming: Bool { model.confirming == row.id }
    private var stripLevel: Double { !model.counted ? 0 : state == nil ? min(1, (stat?.cpu ?? 0) / 100) : 1 }
    private var shownCpu: Int { model.counted ? Int((stat?.cpu ?? 0).rounded()) : 0 }
    private var shownBytes: UInt64 { model.counted ? (stat?.bytes ?? 0) : 0 }
    private var isIdle: Bool { !isOther && state == nil && model.idleRows.contains { $0.pid == row.pid } }
    private var showKeys: Bool { (hover || forced) && state == nil && !confirming }

    var body: some View {
        HStack(spacing: 0) {
            led.padding(.trailing, 12)
            if confirming, let prompt = model.stopPrompt(row) {
                let message = Text(prompt).font(KitFont.bodyMedium).foregroundStyle(KitColor.text)
                    .fixedSize(horizontal: false, vertical: true)
                ViewThatFits(in: .vertical) {
                    message
                    ScrollView { message }
                }
                .padding(.vertical, KitSpace.xs)
            } else {
                Text(String(row.port))
                    .font(KitFont.figure(17)).foregroundStyle(KitColor.text)
                    .lineLimit(1).minimumScaleFactor(0.75)
                    .frame(width: 64, alignment: .leading)
                    .padding(.trailing, 12)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: KitSpace.xs) {
                        Text(row.project.isEmpty ? row.name : row.project)
                            .font(KitFont.bodyMedium).foregroundStyle(KitColor.text).lineLimit(1)
                        if row.checkout?.linked == true {
                            Text("worktree").font(KitFont.detail).foregroundStyle(KitColor.text2)
                                .padding(.horizontal, 5).background(KitColor.well, in: Capsule()).fixedSize()
                        }
                    }
                    detail
                    if row.checkout != nil || model.alsoPorts(row) != nil {
                        HStack(spacing: KitSpace.s) {
                            if let checkout = row.checkout {
                                Label(checkout.branch, systemImage: "arrow.triangle.branch").help(checkout.branch)
                            }
                            if let also = model.alsoPorts(row) { Text(also).help(also) }
                        }.font(KitFont.detail).foregroundStyle(KitColor.text2).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: KitSpace.s)
            trailing
        }
        .padding(.horizontal, KitSpace.l)
        .frame(height: Layout.rowHeight)
        .background(showKeys || confirming ? KitColor.well : Color.clear)
        .overlay(alignment: .bottom) { if !last { KitDivider() } }
        .opacity((isOther ? 0.7 : 1) * (model.shown ? 1 : 0))
        .offset(y: model.shown ? 0 : 8)
        .animation(model.shown ? KitMotion.stagger(index) : nil, value: model.shown)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(KitMotion.soft) { hover = h } }
        .help(row.container.map { "\(row.name), \($0.image)" } ?? (row.cwd.isEmpty ? row.exePath : (row.cwd as NSString).abbreviatingWithTildeInPath))
        .task(id: state) { await run(state) }
    }

    // MARK: pieces

    private var ledColor: Color {
        switch state {
        case .stopping, .gone, .stuck: KitColor.red
        case nil: (stat?.cpu ?? 0) > 80 || isIdle ? KitColor.amber : accent
        }
    }

    private var led: some View {
        KitLed(on: state == nil ? index < model.ledsLit : ledOn, color: ledColor, size: 6)
            .animation(KitMotion.soft, value: ledOn)
            .animation(KitMotion.soft, value: model.ledsLit)
            .animation(KitMotion.soft, value: ledColor)
    }

    @ViewBuilder private var detail: some View {
        if state == .stuck {
            Text("Still running").font(KitFont.detail).foregroundStyle(KitColor.red).lineLimit(1)
        } else if confirming {
            Text("Not a dev server, stop it?").font(KitFont.detail).foregroundStyle(KitColor.red).lineLimit(1)
        } else if let container = row.container {
            Text(container.image).font(KitFont.detail).foregroundStyle(KitColor.text2).lineLimit(1)
        } else {
            UptimeLabel(row: row, name: isOther ? "app" : row.tool,
                        idleSince: isIdle ? model.lastActive[row.pid] : nil)
        }
    }

    @ViewBuilder private var trailing: some View {
        if state == .stuck {
            if row.container != nil {
                Button("Retry stop") { model.stop(row) }.buttonStyle(.kitDestructive)
            } else {
                Button("Force quit") { model.forceQuit(row) }.buttonStyle(.kitDestructive)
            }
        } else if confirming {
            HStack(spacing: KitSpace.xs) {
                Button("Cancel") { model.confirming = nil }.buttonStyle(.kitQuiet)
                Button("Stop") { model.stop(row) }.buttonStyle(.kitDestructive)
            }
        } else {
            HStack(spacing: KitSpace.s) {
                ZStack(alignment: .trailing) {
                    if showKeys {
                        HStack(spacing: 3) {
                            let address = Classifier.databaseAddress(row)
                            if address == nil {
                                KitIconButton(symbol: "arrow.up.right", help: "Open in browser") { model.open(row) }
                            }
                            KitIconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: address == nil ? "Copy URL" : "Copy address") {
                                copy(address ?? row.url.absoluteString)
                            }
                            KitIconButton(symbol: "folder", help: "Reveal folder in Finder") { model.reveal(row) }
                                .disabled(row.project.isEmpty)
                        }
                        .transition(.opacity.combined(with: .offset(x: 4)))
                    } else if row.container != nil {
                        Text("Docker").font(KitFont.detail).foregroundStyle(KitColor.text2)
                    } else {
                        VStack(alignment: .trailing, spacing: 6) {
                            ActivityStrip(level: stripLevel, drain: drain, tint: state == nil ? nil : KitColor.red)
                                .frame(width: 82, height: 8)
                                .drawingGroup()
                                .animation(Layout.frozen ? nil : KitMotion.list, value: stripLevel)
                            HStack(spacing: 6) {
                                Text("\(shownCpu)%").foregroundStyle(KitColor.text2).kitRollingNumber(shownCpu)
                                Text(Fmt.memory(shownBytes)).foregroundStyle(KitColor.text2).kitRollingNumber(shownBytes)
                            }
                            .font(.system(size: 11).monospacedDigit()).lineLimit(1).fixedSize()
                        }
                        .transition(.opacity)
                    }
                }
                .frame(width: Layout.sideColumn, alignment: .trailing)
                StopKey(lit: state != nil) { model.requestStop(row, isOther: isOther) }
            }
        }
    }

    // MARK: behaviour

    private func copy(_ text: String) {
        model.copy(text)
        copied = true
        Task { try? await Task.sleep(for: .seconds(1)); copied = false }
    }

    /// The Stop moment: LED blinks red twice, the strip drains over the 3 s wait.
    private func run(_ s: StopState?) async {
        if Layout.frozen { return }
        switch s {
        case .stopping(let since):
            let left = max(0.1, 3 - Date().timeIntervalSince(since))
            withAnimation(.linear(duration: left)) { drain = 1 }
            for on in [false, true, false, true] {
                try? await Task.sleep(for: .milliseconds(160))
                if Task.isCancelled { return }
                ledOn = on
            }
        case .gone:
            withAnimation(KitMotion.list) { drain = 1 }
        case .stuck:
            ledOn = true; drain = 1
        case nil:
            ledOn = true; drain = 0
        }
    }
}

/// Uptime that ticks on its own 30 s clock, so nothing else in the row re-renders.
struct UptimeLabel: View {
    let row: PortRow
    let name: String
    var idleSince: TimeInterval? = nil
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            let up = idleSince.map { "idle " + Scanner.uptime(seconds: IdleTracker.elapsed(since: $0)) } ?? Scanner.uptime(from: row.started, now: ctx.date)
            Text(up.isEmpty ? name : "\(name), \(up)")
                .font(KitFont.detail).foregroundStyle(KitColor.text2).lineLimit(1)
        }
    }
}

struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.94 : 1).animation(KitMotion.press, value: configuration.isPressed)
    }
}

/// The stop key: outlined, red on hover; stays lit while the process is stopping.
struct StopKey: View {
    var lit = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        let on = hover || lit
        Button(action: action) {
            Image(systemName: "stop.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(on ? KitColor.red : KitColor.text2)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: KitSpace.controlRadius).fill(on ? KitColor.red.opacity(lit ? 0.22 : 0.16) : .clear))
                .overlay(RoundedRectangle(cornerRadius: KitSpace.controlRadius).strokeBorder(on ? KitColor.red.opacity(0.7) : KitColor.line, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .disabled(lit)
        .onHover { hover = $0 }
        .animation(KitMotion.soft, value: on)
        .help("Stop")
        .accessibilityLabel("Stop")
    }
}

/// 12 segments of CPU load. Animatable, so the level and the stop drain move smoothly.
struct ActivityStrip: View, Animatable {
    var level: Double          // 0...1
    var drain: Double = 0      // 0...1, segments switch off from the left
    var tint: Color? = nil
    @Environment(\.kitAccent) private var accent

    nonisolated var animatableData: AnimatablePair<Double, Double> {
        get { .init(level, drain) }
        set { level = newValue.first; drain = newValue.second }
    }

    var body: some View {
        Canvas { ctx, size in
            let n = 12
            let gap: CGFloat = 2
            let w = (size.width - gap * CGFloat(n - 1)) / CGFloat(n)
            for i in 0..<n {
                let pos = Double(i + 1) / Double(n)
                let lit = pos <= level + 0.0001 || (i == 0 && level > 0.003)
                var color = KitColor.line
                if lit {
                    color = tint ?? (pos > 0.9 ? KitColor.red : pos > 0.7 ? KitColor.amber : accent)
                }
                let rect = CGRect(x: CGFloat(i) * (w + gap), y: 0, width: w, height: size.height)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(KitColor.line))
                let alpha = lit ? 1 - min(max(drain * Double(n) - Double(i), 0), 1) : 0
                if alpha > 0 { ctx.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color.opacity(alpha))) }
            }
        }
    }
}

// MARK: - Footer pieces

/// A key with a lit bar when on: "Other apps 3".
struct KeyToggle: View {
    let title: String
    let count: Int
    @Binding var isOn: Bool
    @Environment(\.kitAccent) private var accent
    @State private var hover = false

    var body: some View {
        Button { withAnimation(KitMotion.list) { isOn.toggle() } } label: {
            HStack(spacing: 8) {
                Text(title).font(KitFont.key).foregroundStyle(isOn ? KitColor.text : KitColor.text2)
                Text("\(count)").font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(isOn ? KitColor.text : KitColor.text2)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: KitSpace.controlRadius).fill(isOn ? KitColor.raised : (hover ? KitColor.well : .clear)))
            .overlay(alignment: .bottom) {
                if isOn { Rectangle().fill(accent).frame(height: 2).padding(.horizontal, 1) }
            }
            .clipShape(RoundedRectangle(cornerRadius: KitSpace.controlRadius))
            .overlay(RoundedRectangle(cornerRadius: KitSpace.controlRadius).strokeBorder(KitColor.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .onHover { h in withAnimation(KitMotion.soft) { hover = h } }
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

struct MoreMenu: View {
    let model: HarborModel
    @State private var hover = false

    var body: some View {
        Menu {
            Button("Settings…") { model.onSettings() }.keyboardShortcut(",", modifiers: .command)
            Button("Show intro") { model.onShowIntro() }
            Divider()
            Button("Quit Harbor") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hover ? KitColor.text : KitColor.text2)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: KitSpace.controlRadius).fill(hover ? KitColor.well : .clear))
                .overlay(RoundedRectangle(cornerRadius: KitSpace.controlRadius).strokeBorder(hover ? KitColor.line : .clear, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .onHover { hover = $0 }
    }
}

// MARK: - States

/// Nothing running: a big zero on the board.
struct EmptyBoard: View {
    var others = 0
    var body: some View {
        VStack(spacing: 6) {
            Text("0").font(KitFont.figure(56, .semibold)).foregroundStyle(KitColor.text3)
            Text("No dev servers running").font(KitFont.bodyMedium).foregroundStyle(KitColor.text)
            Text(others == 0 ? "Start one and it shows up here." : "\(others) other app\(others == 1 ? " uses" : "s use") ports. See Other apps below.").font(KitFont.detail).foregroundStyle(KitColor.text2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
}

/// Before the first scan finishes: the real layout, unlit.
struct Skeleton: View {
    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { i in
                HStack(spacing: 0) {
                    KitLed(on: false, size: 6).padding(.trailing, 12)
                    RoundedRectangle(cornerRadius: 5).fill(KitColor.well).frame(width: 86, height: 34).padding(.trailing, 12)
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(KitColor.well).frame(width: 96 - CGFloat(i) * 14, height: 10)
                        RoundedRectangle(cornerRadius: 2).fill(KitColor.well).frame(width: 64, height: 8)
                    }
                    Spacer()
                    ActivityStrip(level: 0).frame(width: 82, height: 8).padding(.trailing, 8 + 26)
                }
                .padding(.horizontal, KitSpace.l)
                .frame(height: Layout.rowHeight)
                .overlay(alignment: .bottom) { if i < 2 { KitDivider() } }
            }
        }
    }
}

/// "Port 3000 is taken by copper-shop": only shown, nothing happens until a key is clicked.
struct PortBanner: View {
    let model: HarborModel
    let conflict: Conflict

    var body: some View {
        VStack(alignment: .leading, spacing: KitSpace.s) {
            HStack(spacing: KitSpace.s) {
                KitLed(on: true, color: KitColor.amber, size: 6)
                Text("Port \(String(conflict.port)) is taken by \(conflict.holderName)")
                    .font(KitFont.bodyMedium).foregroundStyle(KitColor.text).lineLimit(1)
            }
            HStack(spacing: KitSpace.s) {
                if model.dev.contains(where: { $0.id == conflict.holder.id }) {
                    Button("Stop \(conflict.holderName)") { model.stopHolder(conflict) }.buttonStyle(.kitSecondary).lineLimit(1)
                }
                Button("Dismiss") { withAnimation(KitMotion.list) { _ = model.dismissed.insert(conflict.id) } }.buttonStyle(.kitQuiet)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, KitSpace.l)
        .frame(height: Layout.banner)
        .background(KitColor.well)
        .overlay(alignment: .bottom) { KitDivider() }
    }
}
