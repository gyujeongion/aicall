import Cocoa
import AVFoundation
import Contacts

// AI 통화 — 내 번호로 전화 걸어 AI가 대신 통화하는 앱. 엔진(agent.py 등)은 앱 번들 Resources에 들어 있다.
// 앱이 엔진을 자식 프로세스로 실행하므로 시스템 오디오·기기 제어·마이크 권한은 이 앱 하나에만 주면 된다.
// 화면(11-14 B안): 아이폰 통화 화면의 약속을 따른다 — 검은 바탕, 가운데 큰 번호, 아래 둥근 초록 걸기·빨강 끊기, 대화는 말풍선.

let res = Bundle.main.resourcePath!

let homeDir = ProcessInfo.processInfo.environment["HOME"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser   // CLI(aicall)와 같은 홈을 본다
// 엔진에 필요한 모듈이 있는 파이썬을 찾는다
let pythonPath: String = {
    let home = homeDir.path
    for c in ["\(home)/.config/aicall/venv/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"] {
        guard FileManager.default.isExecutableFile(atPath: c) else { continue }
        let t = Process(); t.executableURL = URL(fileURLWithPath: c); t.arguments = ["-c", "import websockets"]
        t.standardError = FileHandle.nullDevice; t.standardOutput = FileHandle.nullDevice
        if (try? t.run()) != nil { t.waitUntilExit(); if t.terminationStatus == 0 { return c } }
    }
    return "/usr/bin/python3"
}()
let support = homeDir.appendingPathComponent("Library/Application Support/AICall")
try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

// 실제 통화는 한 가지다. ARS인지 사람인지는 받은 뒤 첫마디로 엔진이 가른다(live.py 하이브리드, 11-14 탭 통합)
enum Mode: Int { case call = 0, practice = 1 }
// 화면 단계: 대기 → 거는 중 → 통화 중(자동 안내/사람) → 결과
enum Phase { case idle, dialing, talking, done }

let defaultTask: [Mode: String] = [
    .call: "",
    .practice: "식당에 전화했다고 치고 토요일 저녁 7시에 두 명 예약을 잡아 줘.",
]
let systemMic = "시스템 기본"

// 어떻게 입력하든 국내 번호 숫자로: +82 10 …, 82-10-…, (010) … → 010… (aicall norm_phone과 같은 규칙)
func digitsOnly(_ s: String) -> String {
    var d = s.filter(\.isNumber)
    if d.hasPrefix("82"), d.count >= 10 { d = "0" + String(d.dropFirst(2).drop(while: { $0 == "0" })) }
    return d
}

// 입력한 숫자를 전화번호 모양으로 묶는다. 걸기 전에 번호를 눈으로 확인하게
func formatPhone(_ d: String) -> String {
    if d.count == 8, d.first == "1" { return "\(d.prefix(4))-\(d.suffix(4))" }
    let a = d.hasPrefix("02") ? 2 : 3
    guard d.count > a else { return d }
    let rest = d.dropFirst(a)
    if rest.count <= 4 { return "\(d.prefix(a))-\(rest)" }
    let mid = rest.count >= 8 ? 4 : 3
    return "\(d.prefix(a))-\(rest.prefix(mid))-\(rest.dropFirst(mid))"
}

// 맥 연락처: 이름으로 번호 찾기, 번호로 이름 찾기. 권한은 이름을 처음 칠 때(또는 설정 화면에서) 한 번 묻는다
enum Book {
    struct Hit { let name: String; let label: String; let number: String; let key: String }
    static let store = CNContactStore()
    static var cache: [Hit]?
    static var allowed: Bool { CNContactStore.authorizationStatus(for: .contacts) == .authorized }
    static func ask(_ done: @escaping (Bool) -> Void) {
        if allowed { done(true); return }
        store.requestAccess(for: .contacts) { ok, _ in DispatchQueue.main.async { done(ok) } }
    }
    static func squash(_ s: String) -> String { s.lowercased().filter { !$0.isWhitespace } }
    static func all() -> [Hit] {
        if let c = cache { return c }
        guard allowed else { return [] }
        let keys = [CNContactFormatter.descriptorForRequiredKeys(for: .fullName)] +
            ([CNContactNicknameKey, CNContactOrganizationNameKey, CNContactPhoneNumbersKey] as [CNKeyDescriptor])
        var out: [Hit] = []
        try? store.enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { c, _ in
            let full = CNContactFormatter.string(from: c, style: .fullName) ?? ""
            let name = full.isEmpty ? c.organizationName : full
            for p in c.phoneNumbers {
                let d = digitsOnly(p.value.stringValue)
                guard d.count >= 3 else { continue }
                out.append(Hit(name: name, label: p.label.map { CNLabeledValue<NSString>.localizedString(forLabel: $0) } ?? "전화",
                               number: d, key: squash(name + " " + c.nickname + " " + c.organizationName)))
            }
        }
        cache = out
        NotificationCenter.default.addObserver(forName: .CNContactStoreDidChange, object: nil, queue: .main) { _ in cache = nil }
        return out
    }
    static func search(_ q: String) -> [Hit] { let k = squash(q); return k.isEmpty ? [] : all().filter { $0.key.contains(k) } }
    static func who(_ digits: String) -> Hit? { digits.count < 3 ? nil : all().first { $0.number == digits } }
    // 후보가 한 번호로 좁혀질 때만 고른다. 한 사람에 번호가 여럿이면 휴대폰(01…)이 하나일 때 그것 (aicall pick과 같은 규칙)
    static func choose(_ hits: [Hit]) -> Hit? {
        if Set(hits.map(\.number)).count == 1 { return hits.first }
        let mob = hits.filter { $0.number.hasPrefix("01") }
        if Set(hits.map(\.name)).count == 1, Set(mob.map(\.number)).count == 1 { return mob.first }
        return nil
    }
}

// 디자인 토큰. 강조색은 통화 약속 색(걸기 초록·끊기 빨강)과 넘겨받기 주황뿐. 글꼴은 시스템 한 벌, 숫자만 고정폭 숫자
// 최근 통화: 기록 파일(calls/*.md)의 번호·용건·결과. 같은 번호·용건은 한 번만, 화면 점검용 재생은 뺀다
struct Past { let number: String; let task: String; let outcome: String }
func recentCalls(_ n: Int) -> [Past] {
    let dir = support.appendingPathComponent("calls")
    let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".md") }.sorted(by: >)
    var out: [Past] = []
    for f in files.prefix(40) where out.count < n {
        let num = String(f.dropLast(3).split(separator: "_").last ?? "")
        guard num.count >= 3, let s = try? String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8), !s.contains(" 재생: ") else { continue }
        let parts = s.components(separatedBy: "\n\n")
        guard parts.count > 1, parts[1].hasPrefix("용건: ") else { continue }
        let task = String(parts[1].dropFirst(4))
        let end = s.split(separator: "\n").last { $0.hasPrefix("결과: ") }.map { String($0.dropFirst(4).prefix { $0 != " " }) } ?? ""
        if !out.contains(where: { $0.number == num && $0.task == task }) { out.append(Past(number: num, task: task, outcome: end)) }
    }
    return out
}

enum Pal {
    static func hex(_ v: UInt32) -> NSColor { NSColor(srgbRed: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1) }
    static let bg = hex(0x0C0C0D)        // 바탕 (통화 화면)
    static let surface = hex(0x1A1A1C)   // 입력판·작은 단추
    static let line = hex(0x2C2C2F)      // 입력판 테두리
    static let other = hex(0x232326)     // 상대 말풍선
    static let ai = hex(0x123D1F)        // AI 말풍선 (초록을 바탕에 가라앉힌 색)
    static let aiText = hex(0xD7F5DF)
    static let text = hex(0xF2F2F2)
    static let sub = hex(0x8E8E93)       // 보조 글씨 (바탕 대비 6.1:1)
    static let faint = hex(0x6C6C70)     // 안내 글씨 (바탕 대비 3.9:1, 큰 글씨·비필수 안내에만)
    static let green = hex(0x34C759)
    static let red = hex(0xFF453A)
    static let orange = hex(0xFF9F0A)
    static let warnBg = hex(0x2E1F07)
}

func sym(_ name: String, _ size: CGFloat, _ weight: NSFont.Weight = .semibold) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: size, weight: weight))
}

func label(_ s: String, _ size: CGFloat, _ color: NSColor, _ weight: NSFont.Weight = .regular, wrap: Bool = false) -> NSTextField {
    let l = wrap ? NSTextField(wrappingLabelWithString: s) : NSTextField(labelWithString: s)
    l.font = .systemFont(ofSize: size, weight: weight); l.textColor = color; l.isSelectable = false
    return l
}

// 둥근 통화 단추 + 아래 이름. 걸기·끊기·다시 걸기·연습·스피커가 모두 이 모양
final class RoundKey: NSStackView {
    let button = NSButton()
    let name = label("", 11, Pal.sub)
    var fill = Pal.green { didSet { button.layer?.backgroundColor = fill.cgColor } }
    var ink = NSColor.black { didSet { button.contentTintColor = ink } }
    init(diameter: CGFloat, symbolSize: CGFloat) {
        super.init(frame: .zero)
        orientation = .vertical; spacing = 5; alignment = .centerX
        button.isBordered = false; button.title = ""; button.wantsLayer = true
        button.layer?.cornerRadius = diameter / 2; button.imagePosition = .imageOnly
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([button.widthAnchor.constraint(equalToConstant: diameter), button.heightAnchor.constraint(equalToConstant: diameter)])
        self.symbolSize = symbolSize
        addArrangedSubview(button); addArrangedSubview(name)
    }
    required init?(coder: NSCoder) { nil }
    var symbolSize: CGFloat = 20
    func set(_ symbol: String, _ title: String, fill f: NSColor, ink i: NSColor) {
        button.image = sym(symbol, symbolSize); fill = f; ink = i; name.stringValue = title
        button.setAccessibilityLabel(title)
    }
}

// 말풍선 하나. 상대=왼쪽 회색, AI=오른쪽 초록
final class Bubble: NSView {
    let text: NSTextField
    init(_ s: String, mine: Bool) {
        text = label(s, 13, mine ? Pal.aiText : Pal.text, wrap: true)
        text.preferredMaxLayoutWidth = 250; text.isSelectable = true
        super.init(frame: .zero)
        wantsLayer = true; layer?.backgroundColor = (mine ? Pal.ai : Pal.other).cgColor; layer?.cornerRadius = 13
        layer?.maskedCorners = mine ? [.layerMinXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner] : [.layerMinXMaxYCorner, .layerMaxXMaxYCorner, .layerMaxXMinYCorner]   // 말한 쪽 아래 모서리만 각지게
        text.translatesAutoresizingMaskIntoConstraints = false; addSubview(text)
        NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11), text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11),
                                     text.topAnchor.constraint(equalTo: topAnchor, constant: 7), text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7)])
    }
    required init?(coder: NSCoder) { nil }
}

final class Flipped: NSView { override var isFlipped: Bool { true } }

// 거는 중: 초록 고리가 천천히 퍼진다 (이 앱의 유일한 움직임)
final class Ring: NSView {
    let core = NSImageView()
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        core.image = sym("phone.fill", 20); core.contentTintColor = Pal.green
        core.wantsLayer = true; core.layer?.backgroundColor = Pal.ai.cgColor; core.layer?.cornerRadius = 26
        core.imageAlignment = .alignCenter
        core.translatesAutoresizingMaskIntoConstraints = false; addSubview(core)
        NSLayoutConstraint.activate([core.widthAnchor.constraint(equalToConstant: 52), core.heightAnchor.constraint(equalToConstant: 52),
                                     core.centerXAnchor.constraint(equalTo: centerXAnchor), core.centerYAnchor.constraint(equalTo: centerYAnchor),
                                     widthAnchor.constraint(equalToConstant: 120), heightAnchor.constraint(equalToConstant: 120)])
    }
    required init?(coder: NSCoder) { nil }
    var pulses: [CAShapeLayer] = []
    func start() {
        stop(); layoutSubtreeIfNeeded()
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for i in 0..<2 {
            let l = CAShapeLayer()
            l.frame = bounds; l.path = CGPath(ellipseIn: bounds.insetBy(dx: 26, dy: 26), transform: nil)
            l.fillColor = nil; l.strokeColor = Pal.green.withAlphaComponent(0.5).cgColor; l.lineWidth = 1.5
            layer?.insertSublayer(l, at: 0); pulses.append(l)
            if reduce { l.transform = CATransform3DMakeScale(1.3 + CGFloat(i) * 0.35, 1.3 + CGFloat(i) * 0.35, 1); l.opacity = 0.5 - Float(i) * 0.25; continue }
            let s = CABasicAnimation(keyPath: "transform.scale"); s.fromValue = 1.0; s.toValue = 1.8
            let o = CABasicAnimation(keyPath: "opacity"); o.fromValue = 0.8; o.toValue = 0
            let g = CAAnimationGroup(); g.animations = [s, o]; g.duration = 2.0; g.repeatCount = .infinity
            g.timingFunction = CAMediaTimingFunction(name: .easeOut); g.beginTime = CACurrentMediaTime() + Double(i)
            l.add(g, forKey: "pulse")
        }
    }
    func stop() { pulses.forEach { $0.removeFromSuperlayer() }; pulses = [] }
}

final class Controller: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextViewDelegate, NSTextFieldDelegate {
    let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 700),
                       styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    // 위: 번호와 상태
    let number = NSTextField(string: "")
    let suggest = NSStackView()                     // 이름을 치면 연락처 후보가 번호 아래에 뜬다
    var hits: [Book.Hit] = []
    var callee: String?                             // 연락처에서 찾은 상대 이름 · 번호 종류
    let practiceTitle = label("전화 없이 연습", 22, Pal.text, .light)
    let led = NSView()
    let status = label("", 12, Pal.sub)
    let clock = label("", 12, Pal.sub)
    // 용건
    let task = NSTextView()
    let taskLabel = label("용건", 11, Pal.sub, .medium)
    let taskHint = label("예: 광고 문자 수신거부 등록해 줘.\n예: 토요일 저녁 7시에 두 명 예약해 줘.", 13, Pal.faint)
    let taskBox = Flipped()
    let taskLine = label("", 12, Pal.sub)                  // 통화 중엔 용건이 한 줄로 접힌다
    let micRow = NSStackView()
    let micPop = NSPopUpButton()
    let handoff = NSButton(checkboxWithTitle: "민감한 개인정보를 물으면 나에게 알림", target: nil, action: nil)
    let monitor = NSButton(checkboxWithTitle: "통화 소리를 내 스피커로 듣기 (끄면 받아쓰기만)", target: nil, action: nil)
    let opts = NSStackView()
    // 가운데: 단계마다 하나만 보인다
    let hint = label("", 12, Pal.faint, wrap: true)
    let recent = NSStackView()                      // 대기 화면: 최근 통화를 누르면 번호·용건이 다시 채워진다
    var past: [Past] = []
    let ring = Ring()
    let ringNote = label("받으면 첫마디로 자동 안내인지 사람인지 가려요", 11, Pal.faint)
    let banner = NSView()
    let bannerTitle = label("", 13, Pal.text, .semibold, wrap: true)
    let list = NSStackView()
    let chatScroll = NSScrollView()
    let result = NSStackView()
    let resultIcon = NSImageView()
    let resultTitle = label("", 17, Pal.text, .semibold)
    let resultText = label("", 12, Pal.sub, wrap: true)
    let resultMeta = label("", 11, Pal.faint)
    let viewChat = NSButton(title: "대화 보기", target: nil, action: nil)
    let openLogBtn = NSButton(title: "기록 열기", target: nil, action: nil)
    // 아래 단추
    let callKey = RoundKey(diameter: 60, symbolSize: 22)
    let speakerKey = RoundKey(diameter: 44, symbolSize: 16)
    let permRow = NSStackView()

    let cfgURL = support.appendingPathComponent("config.json")
    let reqDir = support.appendingPathComponent("requests")
    var proc: Process?
    var mode = Mode.call
    var phase = Phase.idle
    var line = ""                                   // "ars" | "human" | ""
    var externalNext = false                        // CLI가 --brain external로 요청한 통화
    var requestedSpeakNext = false
    var requestIDNext: String?
    var logPath: String?
    var replayNext: String?                         // 화면 점검용: 저장된 안내를 전화 없이 재생
    var ended = false
    var port = 0                                    // 엔진 제어 포트 (스피커 단추)
    var speakerOn = false
    var startedAt: Date?
    var clockTimer: Timer?
    var lastWho = ""                                // 같은 사람이 이어 말하면 한 말풍선에 붙인다
    var counts = (other: 0, ai: 0)
    var showingChat = false

    func buildMenu() {
        let bar = NSMenu()
        let appItem = NSMenuItem(); bar.addItem(appItem)
        let appMenu = NSMenu()
        let setItem = appMenu.addItem(withTitle: "설정…", action: #selector(openSetup), keyEquivalent: ","); setItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "AI 통화 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem(); bar.addItem(editItem)
        let edit = NSMenu(title: "편집")
        edit.addItem(withTitle: "실행 취소", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "잘라내기", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "복사", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "붙여넣기", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "전체 선택", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        let winItem = NSMenuItem(); bar.addItem(winItem)
        let w = NSMenu(title: "윈도우")
        w.addItem(withTitle: "닫기", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winItem.submenu = w
        NSApp.mainMenu = bar
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu()
        win.title = "AI 통화"; win.titleVisibility = .hidden; win.titlebarAppearsTransparent = true
        win.appearance = NSAppearance(named: .darkAqua)   // 통화 화면은 늘 검다
        win.backgroundColor = Pal.bg
        win.minSize = NSSize(width: 380, height: 620)
        win.center(); win.delegate = self
        let v = win.contentView!


        // 번호
        number.isBordered = false; number.drawsBackground = false; number.focusRingType = .none; number.alignment = .center
        number.font = .monospacedDigitSystemFont(ofSize: 30, weight: .light); number.textColor = Pal.text
        let center = NSMutableParagraphStyle(); center.alignment = .center
        number.placeholderAttributedString = NSAttributedString(string: "번호 또는 이름", attributes: [.font: NSFont.systemFont(ofSize: 30, weight: .light), .foregroundColor: Pal.faint, .paragraphStyle: center])
        number.delegate = self
        led.wantsLayer = true; led.layer?.cornerRadius = 3
        let statusRow = NSStackView(views: [led, status, clock]); statusRow.spacing = 6
        suggest.orientation = .vertical; suggest.alignment = .centerX; suggest.spacing = 2; suggest.isHidden = true
        NSLayoutConstraint.activate([led.widthAnchor.constraint(equalToConstant: 6), led.heightAnchor.constraint(equalToConstant: 6)])
        practiceTitle.alignment = .center

        // 용건 입력판
        task.font = .systemFont(ofSize: 13); task.textColor = Pal.text; task.insertionPointColor = Pal.green
        task.drawsBackground = false; task.isRichText = false; task.allowsUndo = true; task.delegate = self
        task.isVerticallyResizable = true; task.autoresizingMask = [.width]
        task.textContainerInset = .zero; task.textContainer?.lineFragmentPadding = 0
        let taskScroll = NSScrollView(); taskScroll.documentView = task; taskScroll.hasVerticalScroller = true; taskScroll.autohidesScrollers = true
        taskScroll.drawsBackground = false; taskScroll.borderType = .noBorder
        taskHint.maximumNumberOfLines = 3
        taskBox.wantsLayer = true; taskBox.layer?.backgroundColor = Pal.surface.cgColor; taskBox.layer?.cornerRadius = 10
        taskBox.layer?.borderWidth = 1; taskBox.layer?.borderColor = Pal.line.cgColor
        for x in [taskLabel, taskScroll, taskHint] as [NSView] { x.translatesAutoresizingMaskIntoConstraints = false; taskBox.addSubview(x) }
        NSLayoutConstraint.activate([
            taskLabel.leadingAnchor.constraint(equalTo: taskBox.leadingAnchor, constant: 12), taskLabel.topAnchor.constraint(equalTo: taskBox.topAnchor, constant: 9),
            taskScroll.leadingAnchor.constraint(equalTo: taskBox.leadingAnchor, constant: 12), taskScroll.trailingAnchor.constraint(equalTo: taskBox.trailingAnchor, constant: -12),
            taskScroll.topAnchor.constraint(equalTo: taskLabel.bottomAnchor, constant: 4), taskScroll.bottomAnchor.constraint(equalTo: taskBox.bottomAnchor, constant: -10),
            taskScroll.heightAnchor.constraint(equalToConstant: 54),
            taskHint.leadingAnchor.constraint(equalTo: taskScroll.leadingAnchor), taskHint.trailingAnchor.constraint(equalTo: taskScroll.trailingAnchor),
            taskHint.topAnchor.constraint(equalTo: taskScroll.topAnchor),
        ])
        taskLine.lineBreakMode = .byTruncatingTail; taskLine.wantsLayer = true
        let taskLineBox = NSStackView(views: [taskLine]); taskLineBox.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        taskLineBox.wantsLayer = true; taskLineBox.layer?.backgroundColor = Pal.surface.cgColor; taskLineBox.layer?.cornerRadius = 10

        // 연습: 마이크 고르기
        let mics = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
            .devices.map(\.localizedName).filter { !$0.contains("BlackHole") && !$0.hasPrefix("AICall") }
        micPop.addItems(withTitles: [systemMic] + mics); micPop.controlSize = .small
        if let saved = readConfig()["mic"] as? String { micPop.selectItem(withTitle: saved) }
        micPop.target = self; micPop.action = #selector(saveMic)
        micRow.setViews([label("마이크", 12, Pal.sub), NSView(), micPop], in: .leading)
        micRow.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 8)
        micRow.wantsLayer = true; micRow.layer?.backgroundColor = Pal.surface.cgColor; micRow.layer?.cornerRadius = 10

        for b in [handoff, monitor] {
            b.attributedTitle = NSAttributedString(string: b.title, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: Pal.sub])
        }
        handoff.state = .on
        monitor.state = (readConfig()["monitor"] as? Bool ?? false) ? .on : .off
        monitor.target = self; monitor.action = #selector(saveMonitor)
        opts.setViews([handoff, monitor], in: .leading); opts.orientation = .vertical; opts.alignment = .leading; opts.spacing = 4

        // 넘겨받기 띠
        banner.wantsLayer = true; banner.layer?.backgroundColor = Pal.warnBg.cgColor; banner.layer?.cornerRadius = 10
        banner.layer?.borderWidth = 1; banner.layer?.borderColor = Pal.orange.withAlphaComponent(0.35).cgColor
        let bannerText = label("AI는 이 정보를 누르지 않아요. 아이폰 통화 화면의 키패드로 직접 눌러 주세요.", 12, Pal.orange.blended(withFraction: 0.45, of: .white)!, wrap: true)
        let bannerStack = NSStackView(views: [bannerTitle, bannerText]); bannerStack.orientation = .vertical; bannerStack.alignment = .leading; bannerStack.spacing = 3
        bannerStack.translatesAutoresizingMaskIntoConstraints = false; banner.addSubview(bannerStack)
        NSLayoutConstraint.activate([bannerStack.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 12), bannerStack.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -12),
                                     bannerStack.topAnchor.constraint(equalTo: banner.topAnchor, constant: 9), bannerStack.bottomAnchor.constraint(equalTo: banner.bottomAnchor, constant: -9)])
        bannerTitle.preferredMaxLayoutWidth = 320; bannerText.preferredMaxLayoutWidth = 320

        // 대화 말풍선 목록
        list.orientation = .vertical; list.alignment = .leading; list.spacing = 6
        list.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 8, right: 0)
        let doc = Flipped(); list.translatesAutoresizingMaskIntoConstraints = false; doc.addSubview(list)
        doc.translatesAutoresizingMaskIntoConstraints = false
        chatScroll.documentView = doc; chatScroll.drawsBackground = false; chatScroll.hasVerticalScroller = true; chatScroll.autohidesScrollers = true
        NSLayoutConstraint.activate([list.leadingAnchor.constraint(equalTo: doc.leadingAnchor), list.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
                                     list.topAnchor.constraint(equalTo: doc.topAnchor), list.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
                                     doc.widthAnchor.constraint(equalTo: chatScroll.contentView.widthAnchor)])

        // 결과 한 장
        resultIcon.wantsLayer = true; resultIcon.layer?.cornerRadius = 24
        NSLayoutConstraint.activate([resultIcon.widthAnchor.constraint(equalToConstant: 48), resultIcon.heightAnchor.constraint(equalToConstant: 48)])
        resultText.alignment = .center; resultText.preferredMaxLayoutWidth = 300
        for b in [viewChat, openLogBtn] { b.bezelStyle = .rounded; b.controlSize = .small }
        viewChat.target = self; viewChat.action = #selector(toggleResultChat)
        openLogBtn.target = self; openLogBtn.action = #selector(openLog)
        let resultBtns = NSStackView(views: [viewChat, openLogBtn]); resultBtns.spacing = 8
        resultBtns.setHuggingPriority(.required, for: .horizontal)   // 단추가 하나만 보여도 가운데에 온다
        result.setViews([resultIcon, resultTitle, resultText, resultMeta, resultBtns], in: .center)
        result.orientation = .vertical; result.alignment = .centerX; result.spacing = 6
        result.setCustomSpacing(10, after: resultIcon); result.setCustomSpacing(14, after: resultMeta)

        hint.alignment = .center; hint.preferredMaxLayoutWidth = 300

        // 가운데 칸: 대기 안내 / 고리 / 말풍선 / 결과 중 하나
        let middle = NSView()
        let ringBox = NSStackView(views: [ring, ringNote]); ringBox.orientation = .vertical; ringBox.spacing = 14
        recent.orientation = .vertical; recent.alignment = .leading; recent.spacing = 5
        let idleBox = NSStackView(views: [recent, hint]); idleBox.orientation = .vertical; idleBox.spacing = 22
        for x in [idleBox, ringBox, chatScroll, result] as [NSView] { x.translatesAutoresizingMaskIntoConstraints = false; middle.addSubview(x) }
        NSLayoutConstraint.activate([
            idleBox.centerXAnchor.constraint(equalTo: middle.centerXAnchor), idleBox.centerYAnchor.constraint(equalTo: middle.centerYAnchor),
            idleBox.widthAnchor.constraint(equalTo: middle.widthAnchor, constant: -24), recent.widthAnchor.constraint(equalTo: idleBox.widthAnchor),
            ringBox.centerXAnchor.constraint(equalTo: middle.centerXAnchor), ringBox.centerYAnchor.constraint(equalTo: middle.centerYAnchor),
            chatScroll.leadingAnchor.constraint(equalTo: middle.leadingAnchor), chatScroll.trailingAnchor.constraint(equalTo: middle.trailingAnchor),
            chatScroll.topAnchor.constraint(equalTo: middle.topAnchor), chatScroll.bottomAnchor.constraint(equalTo: middle.bottomAnchor),
            result.centerXAnchor.constraint(equalTo: middle.centerXAnchor), result.centerYAnchor.constraint(equalTo: middle.centerYAnchor),
            result.widthAnchor.constraint(lessThanOrEqualTo: middle.widthAnchor),
        ])
        self.ringBox = ringBox

        // 아래 단추
        callKey.button.target = self; callKey.button.action = #selector(toggleCall); callKey.button.keyEquivalent = "\r"
        speakerKey.button.target = self; speakerKey.button.action = #selector(toggleSpeaker)
        let keys = NSStackView(views: [speakerKey, callKey]); keys.spacing = 30; keys.alignment = .top

        let permText = label("전화 앱을 다루려면 '기기 제어 및 데이터 접근' 권한이 필요해요.", 12, Pal.orange)
        let permBtn = NSButton(title: "설정 열기", target: self, action: #selector(openAXSettings)); permBtn.bezelStyle = .inline
        permRow.setViews([permText, permBtn], in: .leading)
        permRow.isHidden = AXIsProcessTrusted()

        let stack = NSStackView(views: [permRow, number, suggest, practiceTitle, statusRow, taskBox, taskLineBox, micRow, opts, banner, middle, keys])
        stack.orientation = .vertical; stack.alignment = .centerX; stack.spacing = 12
        stack.setCustomSpacing(2, after: number); stack.setCustomSpacing(2, after: practiceTitle); stack.setCustomSpacing(16, after: statusRow)
        stack.setCustomSpacing(8, after: taskBox); stack.setCustomSpacing(10, after: middle)
        stack.edgeInsets = NSEdgeInsets(top: 44, left: 16, bottom: 18, right: 16)   // 위 44: 투명 제목줄(신호등) 높이
        stack.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(stack)
        let full: (NSView) -> NSLayoutConstraint = { $0.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32) }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: v.leadingAnchor), stack.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            stack.topAnchor.constraint(equalTo: v.topAnchor), stack.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            full(number), full(taskBox), full(taskLineBox), full(micRow), full(opts), full(banner), full(middle),
            middle.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
        ])
        self.taskLineBox = taskLineBox
        self.statusRow = statusRow

        applyMode(.call, resetTask: true)

        try? FileManager.default.createDirectory(at: reqDir, withIntermediateDirectories: true)
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in self.pollRequests() }
        win.makeKeyAndOrderFront(nil)
        win.makeFirstResponder(number)
        NSApp.activate(ignoringOtherApps: true)
        AVCaptureDevice.requestAccess(for: .audio) { _ in }       // 연습 통화의 마이크
        let axOpts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(axOpts)
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in self.permRow.isHidden = AXIsProcessTrusted() }
        setup.showIfNeeded(on: win)                          // 처음 설치: 키·이름·번호·의존성이 빠졌으면 설정 화면부터
    }
    let setup = Setup()
    @objc func openSetup() { setup.show(on: win) }
    var ringBox: NSStackView!
    var taskLineBox: NSStackView!
    var statusRow: NSStackView!

    func readConfig() -> [String: Any] {
        (try? Data(contentsOf: cfgURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }
    func writeConfig(_ f: (inout [String: Any]) -> Void) {
        var j = readConfig(); f(&j)
        if let d = try? JSONSerialization.data(withJSONObject: j, options: .prettyPrinted) { try? d.write(to: cfgURL) }
    }
    @objc func saveMic() { writeConfig { j in if micPop.titleOfSelectedItem == systemMic { j.removeValue(forKey: "mic") } else { j["mic"] = micPop.titleOfSelectedItem } } }
    @objc func saveMonitor() { writeConfig { j in j["monitor"] = monitor.state == .on } }


    func applyMode(_ m: Mode, resetTask: Bool) {
        let keep = !resetTask && !task.string.isEmpty && task.string != defaultTask[mode]   // 직접 쓴 용건은 지우지 않는다
        mode = m                                           // 연습은 화면에 탭이 없다. CLI(aicall --practice) 요청으로만 들어온다
        if !keep { task.string = defaultTask[m] ?? "" }
        taskLabel.stringValue = m == .practice ? "상황" : "용건"
        enter(.idle)
    }

    // ---- 단계 전환: 무엇을 보이고 숨길지는 여기 한 곳에서만 정한다
    func enter(_ p: Phase) {
        phase = p
        let practice = mode == .practice
        number.isHidden = practice; practiceTitle.isHidden = !practice
        suggest.isHidden = practice || p != .idle || hits.isEmpty
        taskBox.isHidden = p != .idle; taskLineBox.isHidden = p == .idle
        micRow.isHidden = !(practice && p == .idle)
        opts.isHidden = practice || p != .idle
        handoff.isHidden = practice
        if p != .talking { banner.isHidden = true }
        hint.isHidden = p != .idle
        if p == .idle && !practice { loadRecent() } else { recent.isHidden = true }
        ringBox.isHidden = p != .dialing
        if p == .dialing { ring.start() } else { ring.stop() }
        chatScroll.isHidden = !(p == .talking || (p == .done && showingChat))
        result.isHidden = !(p == .done && !showingChat)
        number.isEditable = p == .idle; number.isSelectable = p == .idle
        if p != .idle, win.firstResponder == number.currentEditor() { win.makeFirstResponder(nil) }   // 통화 중엔 번호가 선택된 채 파랗게 남지 않게
        taskLine.stringValue = "\(practice ? "상황" : "용건") · " + task.string.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        speakerKey.isHidden = !(p == .talking && line == "human" && !practice)
        speakerKey.set(speakerOn ? "speaker.wave.2.fill" : "speaker.slash.fill", "내 스피커", fill: speakerOn ? Pal.text : Pal.surface, ink: speakerOn ? .black : Pal.sub)
        switch p {
        case .idle:
            callKey.set(practice ? "mic.fill" : "phone.fill", practice ? "연습 시작" : "전화 걸기", fill: Pal.green, ink: .black)
            setStatus(practice ? "맥 마이크와 스피커로 AI와 말해 봐요" : "대기 중")
            clock.stringValue = ""; light(nil)
            updateReady()
        case .dialing, .talking:
            callKey.set(practice ? "stop.fill" : "phone.down.fill", practice ? "연습 끝내기" : "끊기", fill: Pal.red, ink: .white)
            callKey.alphaValue = 1
        case .done:
            callKey.set(practice ? "mic.fill" : "phone.fill", practice ? "다시 연습" : "다시 걸기", fill: Pal.green, ink: .black)
            callKey.alphaValue = 1
        }
    }

    // 번호·용건이 다 있어야 걸기 단추가 또렷해진다
    func updateReady() {
        guard phase == .idle else { return }
        let practice = mode == .practice
        let named = nameMode ? Book.choose(hits) != nil : number.stringValue.filter(\.isNumber).count >= 3
        let ready = (practice || named) && !task.string.trimmingCharacters(in: .whitespaces).isEmpty
        taskHint.isHidden = !task.string.isEmpty
        callKey.alphaValue = ready ? 1 : 0.35
        hint.stringValue = ready ? "엔터를 누르면 \(practice ? "시작해요" : "걸어요"). 줄바꿈은 Shift+엔터."
            : (practice ? "시작하면 먼저 말을 걸어 주세요. 내가 상대 역할이에요." : "자동 안내면 AI가 번호를 누르고, 사람이 받으면 비서라고 밝힌 뒤 대화해요.")
        if !practice {
            if nameMode { setStatus(!Book.allowed ? "연락처 권한이 없어요 — 설정 > 연락처" : hits.isEmpty ? "연락처에서 못 찾았어요" : "후보를 골라 주세요", Book.allowed ? nil : Pal.orange) }
            else { setStatus(callee ?? (number.stringValue.isEmpty ? "번호나 연락처 이름을 넣어요" : "대기 중")) }
        }
    }
    var nameMode: Bool { number.stringValue.unicodeScalars.contains { CharacterSet.letters.contains($0) } }

    func textDidChange(_ n: Notification) { updateReady() }
    func controlTextDidChange(_ n: Notification) {
        if nameMode {                                   // 이름을 치면 연락처에서 찾는다 (권한은 처음 한 번 묻는다)
            callee = nil
            if Book.allowed { showHits(Book.search(number.stringValue)) }
            else { Book.ask { ok in if ok { self.controlTextDidChange(n) } else { self.updateReady() } } }
        } else {
            number.stringValue = formatPhone(String(digitsOnly(number.stringValue).prefix(13)))
            showHits([])
            callee = Book.who(digitsOnly(number.stringValue)).map { "\($0.name) · \($0.label)" }
        }
        updateReady()
    }
    // 엔터: 번호 칸에서는 용건으로 넘어가고(용건이 있으면 건다), 용건 칸에서는 건다. Shift+엔터는 줄바꿈
    func control(_ c: NSControl, textView: NSTextView, doCommandBy s: Selector) -> Bool {
        guard c === number, s == #selector(NSResponder.insertNewline(_:)) else { return false }
        if nameMode {
            guard let h = Book.choose(hits) else { updateReady(); light(Pal.orange); return true }
            pick(h)
        }
        if task.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { win.makeFirstResponder(task) } else { toggleCall() }
        return true
    }
    func textView(_ t: NSTextView, doCommandBy s: Selector) -> Bool {
        if s == #selector(NSResponder.insertNewline(_:)) {
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { return false }
            toggleCall(); return true
        }
        if s == #selector(NSResponder.insertTab(_:)) {       // 번호 칸으로: 전체 선택 대신 끝에 커서를 둔다 (한 글자 치면 번호가 통째로 지워지지 않게)
            win.makeFirstResponder(number); number.currentEditor()?.selectedRange = NSRange(location: (number.stringValue as NSString).length, length: 0); return true
        }
        return false
    }

    func loadRecent() {
        past = recentCalls(4)
        var rows: [NSView] = past.isEmpty ? [] : [label("최근 통화", 11, Pal.faint, .medium)]
        let dot: [String: NSColor] = ["success": Pal.green, "needs_user": Pal.orange, "failed": Pal.red]
        for (i, p) in past.enumerated() {
            let b = NSButton(title: "", target: self, action: #selector(pickPast(_:))); b.tag = i; b.isBordered = false; b.alignment = .left
            let who = (Book.allowed ? Book.who(p.number)?.name : nil) ?? formatPhone(p.number)
            let t = NSMutableAttributedString(string: "●  ", attributes: [.font: NSFont.systemFont(ofSize: 7), .foregroundColor: dot[p.outcome] ?? Pal.faint, .baselineOffset: 2])
            t.append(NSAttributedString(string: who + "  ", attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: Pal.text]))
            t.append(NSAttributedString(string: p.task.replacingOccurrences(of: "\n", with: " "), attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: Pal.sub]))
            b.attributedTitle = t; b.lineBreakMode = .byTruncatingTail
            b.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            rows.append(b)
        }
        recent.setViews(rows, in: .top); recent.isHidden = past.isEmpty
        for b in rows.dropFirst() { b.widthAnchor.constraint(equalTo: recent.widthAnchor).isActive = true }
    }
    @objc func pickPast(_ b: NSButton) {
        let p = past[b.tag]
        number.stringValue = formatPhone(p.number); showHits([])
        callee = Book.allowed ? Book.who(p.number).map { "\($0.name) · \($0.label)" } : nil
        task.string = p.task; updateReady(); win.makeFirstResponder(task)
    }

    func showHits(_ h: [Book.Hit]) {
        hits = h
        suggest.setViews(h.prefix(4).enumerated().map { i, x in
            let b = NSButton(title: "", target: self, action: #selector(pickHit(_:))); b.tag = i; b.isBordered = false
            let t = NSMutableAttributedString(string: x.name + "  ", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: Pal.text])
            t.append(NSAttributedString(string: "\(x.label) \(formatPhone(x.number))", attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular), .foregroundColor: Pal.sub]))
            b.attributedTitle = t
            return b
        }, in: .center)
        suggest.isHidden = h.isEmpty || phase != .idle
    }
    @objc func pickHit(_ b: NSButton) { pick(hits[b.tag]); win.makeFirstResponder(task) }
    func pick(_ h: Book.Hit) {
        number.stringValue = formatPhone(h.number); callee = "\(h.name) · \(h.label)"
        showHits([]); updateReady()
    }

    @objc func openLog() { if let p = logPath { NSWorkspace.shared.open(URL(fileURLWithPath: p)) } }
    @objc func openAXSettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
    @objc func toggleResultChat() { showingChat.toggle(); viewChat.title = showingChat ? "결과 보기" : "대화 보기"; enter(.done) }

    // 통화 중 스피커: 엔진 제어 포트로 바로 알린다 (다음 통화의 기본값은 바꾸지 않는다)
    @objc func toggleSpeaker() {
        speakerOn.toggle(); enter(phase)
        guard port > 0, let u = URL(string: "http://127.0.0.1:\(port)/monitor") else { return }
        var r = URLRequest(url: u); r.httpMethod = "POST"; r.httpBody = try? JSONSerialization.data(withJSONObject: ["on": speakerOn])
        URLSession.shared.dataTask(with: r).resume()
    }

    // CLI(aicall)·MCP가 requests/*.json 을 넣으면 이 앱이 그 전화를 건다 (권한은 이 앱에만 있으면 된다)
    func pollRequests() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: reqDir, includingPropertiesForKeys: nil) else { return }
        for f in files where f.pathExtension == "json" {
            guard let d = try? Data(contentsOf: f), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            try? FileManager.default.removeItem(at: f)
            if let expires = j["expires_at"] as? Double, Date().timeIntervalSince1970 > expires { continue }
            if let q = j["lookup"] as? String {          // aicall contacts / aicall call 이름 — 연락처 권한은 이 앱에만 있다
                let reply = f.deletingPathExtension().appendingPathExtension("reply")
                Book.ask { ok in
                    let o: [String: Any] = ok ? ["matches": Book.search(q).prefix(20).map { ["name": $0.name, "label": $0.label, "number": $0.number] }]
                        : ["error": "연락처 권한이 없어요 — 시스템 설정 > 개인정보 보호 및 보안 > 연락처에서 AI 통화를 켜 주세요"]
                    try? JSONSerialization.data(withJSONObject: o).write(to: reply, options: .atomic)
                }
                continue
            }
            if let p = proc, p.isRunning {
                try? "{\"error\":\"busy\"}".write(to: f.deletingPathExtension().appendingPathExtension("reply"), atomically: true, encoding: .utf8); continue
            }
            if j["selftest"] as? Bool == true {
                let t = Process(); t.executableURL = URL(fileURLWithPath: pythonPath)
                t.arguments = ["\(res)/agent.py", "0", "x", "--selftest"]; t.currentDirectoryURL = URL(fileURLWithPath: res)
                var e = ProcessInfo.processInfo.environment; e["AICALL_DATA"] = support.path
                e["PYTHONDONTWRITEBYTECODE"] = "1"
                e["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (e["PATH"] ?? ""); t.environment = e
                try? t.run(); continue
            }
            let m: Mode = (j["practice"] as? Bool ?? false) ? .practice : .call   // CLI의 --speak 유무와 상관없이 같은 통화(자동 판별)
            applyMode(m, resetTask: true)
            number.stringValue = formatPhone(digitsOnly(j["number"] as? String ?? "")); showHits([])
            callee = (j["callee"] as? String) ?? Book.who(digitsOnly(number.stringValue)).map { "\($0.name) · \($0.label)" }
            if let t = j["task"] as? String, !t.isEmpty { task.string = t }
            handoff.state = (j["handoff"] as? Bool ?? true) ? .on : .off
            externalNext = (j["brain"] as? String) == "external"
            requestedSpeakNext = j["speak"] as? Bool ?? false
            requestIDNext = j["request_id"] as? String
            replayNext = j["replay"] as? String
            win.makeKeyAndOrderFront(nil)
            updateReady()
            toggleCall()
        }
    }

    func windowWillClose(_ n: Notification) { }
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows f: Bool) -> Bool { win.makeKeyAndOrderFront(nil); return true }
    func applicationWillTerminate(_ n: Notification) {
        if let p = proc, p.isRunning { p.terminate(); p.waitUntilExit() }   // 앱을 닫아도 통화가 남지 않게 끊는다
    }

    func setStatus(_ s: String, _ color: NSColor? = nil) {
        status.stringValue = s; status.textColor = color ?? Pal.sub
        if let c = color { light(c) }
    }
    func light(_ c: NSColor?) { led.isHidden = c == nil; led.layer?.backgroundColor = c?.cgColor }

    func startClock() {
        clockTimer?.invalidate(); startedAt = Date(); clock.stringValue = "· 0:00"
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            let t = Int(Date().timeIntervalSince(self.startedAt ?? Date())); self.clock.stringValue = String(format: "· %d:%02d", t / 60, t % 60)
        }
    }

    @objc func toggleCall() {
        if let p = proc, p.isRunning { setStatus("끊는 중"); callKey.button.isEnabled = false; p.terminate(); return }
        if phase == .done { showingChat = false; viewChat.title = "대화 보기"; enter(.idle); return }   // 결과 화면의 '다시 걸기' = 입력 화면으로
        let practice = mode == .practice
        var num = "0"
        if !practice {
            if nameMode {
                guard let h = Book.choose(hits) else { setStatus(hits.isEmpty ? "연락처에서 못 찾았어요" : "후보를 골라 주세요", Pal.orange); return }
                pick(h)
            }
            num = digitsOnly(number.stringValue)
            guard num.count >= 3, num.count <= 12 else { setStatus("번호를 확인해 주세요", Pal.red); win.makeFirstResponder(number); return }
        }
        let goal = task.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty else { setStatus("용건을 적어 주세요", Pal.red); win.makeFirstResponder(task); return }
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        lastWho = ""; counts = (0, 0); line = ""; logPath = nil; ended = false; port = 0; showingChat = false
        speakerOn = monitor.state == .on
        let p = Process()
        p.executableURL = URL(fileURLWithPath: pythonPath)
        var a = ["\(res)/agent.py", num, goal]
        if mode == .call && (!externalNext || requestedSpeakNext) { a.append("--speak") }
        requestedSpeakNext = false
        if let id = requestIDNext { a += ["--request-id", id]; requestIDNext = nil }
        if practice { a.append("--practice") }
        if handoff.state == .on && !practice { a.append("--handoff") }
        if externalNext { a += ["--brain", "external"]; externalNext = false }
        if let r = replayNext { a += ["--replay", r]; replayNext = nil }
        p.arguments = a
        p.currentDirectoryURL = URL(fileURLWithPath: res)
        var env = ProcessInfo.processInfo.environment
        env["AICALL_DATA"] = support.path
        env["PYTHONDONTWRITEBYTECODE"] = "1"   // 서명된 번들 안에 __pycache__를 만들지 않는다
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        p.environment = env
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        var pending = ""
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }      // 프로세스가 끝나면 핸들러를 떼어 빈 읽기 무한 반복을 막는다
            guard let s = String(data: d, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                pending += s.replacingOccurrences(of: "\r", with: "\n")   // 도구의 진행 표시(\r)가 엔진 줄과 붙지 않게
                while let r = pending.range(of: "\n") {               // 줄이 잘려 들어와도 온전한 줄만 그린다
                    let l = String(pending[..<r.lowerBound]); pending = String(pending[r.upperBound...])
                    if !l.isEmpty { self.render(l) }
                }
            }
        }
        p.terminationHandler = { _ in DispatchQueue.main.async {
            self.clockTimer?.invalidate(); self.callKey.button.isEnabled = true
            if !self.ended { self.showResult("ended", "통화가 끝났어요", "") }
        } }
        do {
            try p.run(); proc = p
            enter(practice ? .talking : .dialing); startClock()
            setStatus(practice ? "준비하는 중" : "전화 거는 중", Pal.green)
        } catch { setStatus("앱 엔진을 실행하지 못했어요", Pal.red) }
    }

    // ---- 대화 목록
    func scrollDown() { DispatchQueue.main.async { self.chatScroll.documentView?.scroll(NSPoint(x: 0, y: self.chatScroll.documentView!.bounds.height)) } }

    func row(_ v: NSView, align: NSLayoutConstraint.Attribute) {
        if align == .centerX, let t = v as? NSTextField {        // 시스템 안내 줄은 가운데
            t.alignment = .center; list.addArrangedSubview(t); t.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true; return
        }
        let r = NSStackView(); r.orientation = .horizontal
        if align == .trailing { r.setViews([NSView(), v], in: .leading) } else if align == .centerX { r.setViews([NSView(), v, NSView()], in: .leading) } else { r.setViews([v, NSView()], in: .leading) }
        list.addArrangedSubview(r)
        r.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
    }

    func say(_ who: String, _ text: String) {
        let mine = who == "AI"
        if mine { counts.ai += 1 } else { counts.other += 1 }
        if lastWho == who, let r = list.arrangedSubviews.last as? NSStackView, let b = r.arrangedSubviews.compactMap({ $0 as? Bubble }).first {
            b.text.stringValue += (b.text.stringValue.hasSuffix(" ") ? "" : " ") + text   // 받아쓰기가 조각으로 와도 한 말풍선에
        } else {
            row(Bubble(text, mine: mine), align: mine ? .trailing : .leading)
        }
        lastWho = who; scrollDown()
    }

    func keyPress(_ keys: String) {
        let s = NSMutableAttributedString()
        let att = NSTextAttachment(); att.image = sym("circle.grid.3x3.fill", 10, .regular)
        s.append(NSAttributedString(attachment: att))
        s.append(NSAttributedString(string: "  \(keys) 눌렀어요"))
        s.addAttributes([.foregroundColor: Pal.green, .font: NSFont.systemFont(ofSize: 11, weight: .medium)], range: NSRange(location: 0, length: s.length))
        let l = NSTextField(labelWithAttributedString: s)
        row(l, align: .trailing); counts.ai += 1; lastWho = "key"; scrollDown()
    }

    func sys(_ text: String, _ color: NSColor = Pal.faint) {
        row(label(text, 11, color), align: .centerX); lastWho = "sys"; scrollDown()
    }

    func showResult(_ o: String, _ title: String, _ summary: String) {
        ended = true; clockTimer?.invalidate()
        let look: [String: (String, NSColor)] = ["success": ("checkmark", Pal.green), "failed": ("xmark", Pal.red), "needs_user": ("exclamationmark", Pal.orange), "timeout": ("exclamationmark", Pal.orange)]
        let (icon, col) = look[o] ?? ("phone.down.fill", Pal.surface)
        resultIcon.image = sym(icon, 20, .bold); resultIcon.contentTintColor = col == Pal.surface ? Pal.sub : .black
        resultIcon.layer?.backgroundColor = col.cgColor
        resultTitle.stringValue = title
        resultText.stringValue = summary; resultText.isHidden = summary.isEmpty
        let f = DateFormatter(); f.locale = Locale(identifier: "ko_KR"); f.dateFormat = "a h:mm"
        resultMeta.stringValue = (mode == .practice ? "" : "상대 \(counts.other)번 · AI \(counts.ai)번 · ") + f.string(from: Date())
        openLogBtn.isHidden = logPath == nil
        status.stringValue = (clock.stringValue.isEmpty ? "" : "통화 " + clock.stringValue.replacingOccurrences(of: "· ", with: "")); status.textColor = Pal.sub
        clock.stringValue = ""; light(o == "ended" ? nil : col)
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest); NSSound(named: "Glass")?.play() }   // 다른 일을 하는 동안 끝났다
        enter(.done)
    }

    func render(_ line: String) {
        if line.hasPrefix("{") {                                      // 최종 결과 JSON
            guard let j = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let o = j["outcome"] as? String else { return }
            let titles = ["success": "용건을 마쳤어요", "needs_user": "직접 확인이 필요해요", "failed": "용건을 못 마쳤어요", "timeout": "시간이 다 됐어요"]
            let summary = j["summary"] as? String ?? ""
            if let l = j["log"] as? String { logPath = l }
            if summary == "직접 끊었어요" { showResult("ended", "직접 끊었어요", "") } else { showResult(o, titles[o] ?? o, summary) }
            return
        }
        guard let r = line.range(of: ": "), line.count > 9 else { return }
        let head = line[..<r.lowerBound].split(separator: " ", maxSplits: 1)
        guard head.count > 1, head[0].filter({ $0 == ":" }).count == 2 else { return }   // 엔진 이벤트 줄만 그린다 (도구 경고 등은 기록 파일에만)
        let tag = String(head[1]); let body = String(line[r.upperBound...])
        switch tag {
        case "시작":
            if let m = body.range(of: #"제어포트 (\d+)"#, options: .regularExpression) { port = Int(body[m].split(separator: " ").last ?? "") ?? 0 }
        case "상대":
            if phase == .dialing { enter(.talking); setStatus("통화 중", Pal.green) }
            say("상대", body)
        case "상대구분":
            self.line = body.contains("사람") ? "human" : "ars"
            if phase == .dialing { enter(.talking) }
            setStatus(self.line == "human" ? "사람과 통화" : "자동 안내", Pal.green)
            sys(self.line == "human" ? "사람이 받았어요" : "자동 안내로 판별했어요")
            enter(phase)
        case "AI말함": if phase == .dialing { enter(.talking) }; say("AI", body)
        case "AI누름": keyPress(String(body.split(separator: " ").first ?? ""))
        case "발신": if body.hasPrefix("OK") { setStatus("신호 가는 중", Pal.green) } else if !body.hasPrefix("연습") { sys(body, Pal.red) }
        case "세션": if mode == .practice { setStatus("먼저 말을 걸어 주세요", Pal.green) }
        case "종료": sys("상대가 전화를 끊었어요")
        case "입력실패": sys("키패드가 눌리지 않았어요", Pal.red)
        case "오류": sys(body, Pal.red)
        case "넘겨받기":
            setStatus("직접 입력이 필요해요", Pal.orange)
            bannerTitle.stringValue = body; banner.isHidden = false
            sys("AI가 기다리는 중")
            NSApp.requestUserAttention(.criticalRequest); NSSound(named: "Glass")?.play()
        default: break                                                // 지연·판정·사용량 같은 내부 기록은 파일에만 남긴다
        }
    }
}

// ---- 처음 설정: `aicall doctor --json`(CLI와 같은 점검)을 보여주고, 키·이름·번호를 `aicall setup`으로 저장한다
final class Setup: NSObject {
    let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
    let checks = NSStackView()
    let key = NSSecureTextField(string: "")
    let name = NSTextField(string: "")
    let phone = NSTextField(string: "")
    let err = label("", 12, Pal.red, wrap: true)
    var parent: NSWindow?

    func run(_ args: [String]) -> (Int32, Data) {
        let t = Process(); t.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        t.arguments = [res + "/aicall"] + args
        let o = Pipe(); t.standardOutput = o; t.standardError = FileHandle.nullDevice
        guard (try? t.run()) != nil else { return (-1, Data()) }
        let d = o.fileHandleForReading.readDataToEndOfFile(); t.waitUntilExit()
        return (t.terminationStatus, d)
    }
    func doctor() -> [[String: Any]] {
        var r = (try? JSONSerialization.jsonObject(with: run(["doctor", "--json"]).1) as? [[String: Any]]) ?? []
        r.append(["id": "ax", "name": "기기 제어 권한 (번호 넣기·키패드·끊기)", "ok": AXIsProcessTrusted(), "fix": "시스템 설정 > 개인정보 보호 및 보안 > 기기 제어 및 데이터 접근에서 AI 통화를 켜요"])
        r.append(["id": "contacts", "name": "연락처 (선택 · 이름으로 걸기)", "ok": Book.allowed, "optional": true])
        return r
    }
    func missing() -> Bool { doctor().contains { !($0["ok"] as? Bool ?? false) && !($0["optional"] as? Bool ?? false) } }
    func showIfNeeded(on w: NSWindow) { if missing() { show(on: w) } }

    func field(_ f: NSTextField, _ title: String, _ ph: String) -> NSView {
        f.placeholderString = ph; f.font = .systemFont(ofSize: 13); f.bezelStyle = .roundedBezel; f.focusRingType = .none
        let s = NSStackView(views: [label(title, 11, Pal.sub, .medium), f]); s.orientation = .vertical; s.alignment = .leading; s.spacing = 4
        f.translatesAutoresizingMaskIntoConstraints = false; f.widthAnchor.constraint(equalToConstant: 316).isActive = true
        return s
    }

    func show(on w: NSWindow) {
        parent = w
        if panel.contentView?.subviews.isEmpty ?? true { build() }
        refresh()
        if let v = panel.contentView?.subviews.first { panel.setContentSize(v.fittingSize) }   // 점검 줄 수에 맞춰 높이를 정한다
        if panel.sheetParent == nil { w.beginSheet(panel) }
    }

    func build() {
        panel.appearance = NSAppearance(named: .darkAqua); panel.backgroundColor = Pal.bg
        let icon = NSImageView(image: sym("phone.badge.checkmark", 26) ?? NSImage()); icon.contentTintColor = Pal.green
        let title = label("처음 설정", 17, Pal.text, .semibold)
        let sub = label("AI가 내 번호로 전화하려면 아래가 준비돼야 해요.\n키와 내 정보는 여기서 넣고, 나머지는 안내된 명령으로 고쳐요.", 12, Pal.sub, wrap: true)
        sub.preferredMaxLayoutWidth = 316
        checks.orientation = .vertical; checks.alignment = .leading; checks.spacing = 7
        let card = NSStackView(views: [checks]); card.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        card.wantsLayer = true; card.layer?.backgroundColor = Pal.surface.cgColor; card.layer?.cornerRadius = 10
        let c = (try? JSONSerialization.jsonObject(with: (try? Data(contentsOf: support.appendingPathComponent("config.json"))) ?? Data()) as? [String: Any]) ?? [:]
        name.stringValue = c["owner_name"] as? String ?? ""; phone.stringValue = c["owner_phone"] as? String ?? ""
        prefillFromMe()
        let keyNote = label("키는 이 맥의 ~/.config/aicall/.env 에만 저장돼요. 비워 두면 기존 키를 그대로 써요.", 11, Pal.faint, wrap: true)
        keyNote.preferredMaxLayoutWidth = 316
        let phoneNote = label("전화는 아이폰을 거쳐 나가요. 아이폰 설정 > 앱 > 전화 > 다른 기기에서 통화 허용에서 이 맥을 켜고, 맥 전화 앱 설정의 'iPhone 통화'도 켜 주세요.", 11, Pal.sub, wrap: true)
        phoneNote.preferredMaxLayoutWidth = 316
        let guide = NSButton(title: "처음 설정 안내 전체 보기", target: self, action: #selector(openGuide)); guide.bezelStyle = .inline; guide.controlSize = .small
        let later = NSButton(title: "나중에", target: self, action: #selector(close)); later.bezelStyle = .rounded
        let save = NSButton(title: "저장", target: self, action: #selector(saveTapped)); save.bezelStyle = .rounded; save.keyEquivalent = "\r"
        let btns = NSStackView(views: [NSView(), later, save]); btns.spacing = 8
        err.preferredMaxLayoutWidth = 316
        let stack = NSStackView(views: [icon, title, sub, card, phoneNote, guide,
                                        field(key, "OpenAI API 키", "sk-…"), keyNote,
                                        field(name, "전화에서 밝힐 내 이름", ""),
                                        field(phone, "내 휴대폰 번호 (이 번호로 걸려요)", ""), err, btns])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.setCustomSpacing(4, after: icon); stack.setCustomSpacing(14, after: sub); stack.setCustomSpacing(10, after: card); stack.setCustomSpacing(6, after: phoneNote); stack.setCustomSpacing(16, after: guide); stack.setCustomSpacing(4, after: stack.views[6])
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 32, bottom: 20, right: 32)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let v = panel.contentView!; v.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: v.leadingAnchor), stack.trailingAnchor.constraint(equalTo: v.trailingAnchor),
                                     stack.topAnchor.constraint(equalTo: v.topAnchor), stack.bottomAnchor.constraint(equalTo: v.bottomAnchor),
                                     card.widthAnchor.constraint(equalToConstant: 316), btns.widthAnchor.constraint(equalToConstant: 316)])
    }

    func refresh() {
        checks.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for r in doctor() {
            let ok = r["ok"] as? Bool ?? false
            let mark = NSImageView(image: sym(ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill", 13) ?? NSImage())
            mark.contentTintColor = ok ? Pal.green : Pal.orange
            let n = label(r["name"] as? String ?? "", 12, ok ? Pal.sub : Pal.text, ok ? .regular : .medium)
            let row = NSStackView(views: [mark, n]); row.spacing = 7
            if !ok, r["id"] as? String == "contacts" {
                let b = NSButton(title: "허용", target: self, action: #selector(allowContacts)); b.bezelStyle = .inline; b.controlSize = .small
                row.addArrangedSubview(b)
            }
            if !ok, r["id"] as? String == "ax" {            // 권한은 명령으로 못 고친다: 설정의 그 화면을 바로 연다
                let b = NSButton(title: "설정 열기", target: self, action: #selector(openAX)); b.bezelStyle = .inline; b.controlSize = .small
                row.addArrangedSubview(b)
            }
            checks.addArrangedSubview(row)
            if !ok, r["optional"] == nil, let fix = r["fix"] as? String, !["key", "owner"].contains(r["id"] as? String ?? "") {
                let f = label(fix, 11, Pal.sub, wrap: true); f.isSelectable = true
                f.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular); f.preferredMaxLayoutWidth = 270
                let fr = NSStackView(views: [f]); fr.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 2, right: 0)
                checks.addArrangedSubview(fr)
            }
        }
    }

    @objc func saveTapped() {
        var a = ["setup"]
        let k = key.stringValue.trimmingCharacters(in: .whitespaces)
        if !k.isEmpty { a += ["--key", k] }
        if !name.stringValue.isEmpty { a += ["--name", name.stringValue] }
        if !phone.stringValue.isEmpty { a += ["--phone", phone.stringValue] }
        let (code, out) = run(a)
        if code != 0 {
            let j = (try? JSONSerialization.jsonObject(with: out) as? [String: Any]) ?? [:]
            err.stringValue = j["error"] as? String ?? "저장하지 못했어요"; return
        }
        err.stringValue = ""; key.stringValue = ""
        refresh()
        if let v = panel.contentView?.subviews.first { panel.setContentSize(v.fittingSize) }
        if !missing() { close() }
    }
    @objc func close() { parent?.endSheet(panel) }
    @objc func openAX() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
    @objc func openGuide() { NSWorkspace.shared.open(URL(string: "https://github.com/gyujeongion/aicall/blob/main/docs/setup-ko.md")!) }
    // 연락처: 처음이면 권한 창, 이미 거절했으면 시스템 설정을 연다
    @objc func allowContacts() {
        if CNContactStore.authorizationStatus(for: .contacts) == .notDetermined {
            Book.ask { _ in self.prefillFromMe(); self.refresh(); if let v = self.panel.contentView?.subviews.first { self.panel.setContentSize(v.fittingSize) } }
        } else { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts")!) }
    }
    // 빈 칸이면 연락처의 '내 카드'로 이름·번호를 채워 둔다 (저장은 사용자가 누를 때)
    func prefillFromMe() {
        guard Book.allowed, name.stringValue.isEmpty || phone.stringValue.isEmpty,
              let me = try? Book.store.unifiedMeContactWithKeys(toFetch: [CNContactFormatter.descriptorForRequiredKeys(for: .fullName), CNContactPhoneNumbersKey as CNKeyDescriptor]) else { return }
        if name.stringValue.isEmpty { name.stringValue = CNContactFormatter.string(from: me, style: .fullName) ?? "" }
        if phone.stringValue.isEmpty, let p = me.phoneNumbers.map({ digitsOnly($0.value.stringValue) }).first(where: { $0.hasPrefix("01") }) { phone.stringValue = p }
    }
}

let app = NSApplication.shared
let ctl = Controller()
app.delegate = ctl
app.setActivationPolicy(.regular)
app.run()
