import Cocoa
import ApplicationServices

// macOS 27 전화(Phone.app) 조작기 — 접근성(AX)으로 발신·통화 중 키패드·종료를 한다. 화면 좌표·마우스 이벤트를 쓰지 않는다.
//   phonectl dial <번호>        전화 앱 키패드에 번호를 넣고 '통화'를 누른다 (입력값이 번호와 다르면 걸지 않는다)
//   phonectl dtmf <키들>        통화 중 키패드 숫자 입력 (통화 중 배너의 키패드를 처음 한 번 연다)
//   phonectl hangup             통화 종료
//   phonectl state              통화 중이면 "incall", 아니면 "idle" (배너 버튼 설명도 함께)
//   phonectl dump <번들ID>      AX 트리 덤프 (진단용)
// 종료코드: 0 성공 / 2 인자 / 3 전화 앱 문제 / 4 버튼 못 찾음 / 5 입력값 불일치

let PHONE = "com.apple.mobilephone"
let NC = "com.apple.notificationcenterui"

func attr(_ e: AXUIElement, _ a: String) -> AnyObject? { var v: AnyObject?; AXUIElementCopyAttributeValue(e, a as CFString, &v); return v }
func str(_ e: AXUIElement, _ a: String) -> String { if let x = attr(e, a) { return "\(x)" }; return "" }
func kids(_ e: AXUIElement) -> [AXUIElement] { (attr(e, "AXChildren") as? [AXUIElement]) ?? [] }

struct Node { let el: AXUIElement; let role, title, desc, ident, value: String }

func collect(_ bid: String, maxDepth: Int = 16) -> [Node] {
    guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bid }) else { return [] }
    var out: [Node] = []
    func walk(_ e: AXUIElement, _ d: Int) {
        if d > maxDepth { return }
        let role = str(e, "AXRole")
        if role == "AXMenuBar" { return }                      // 메뉴는 잡음이라 건너뛴다
        out.append(Node(el: e, role: role, title: str(e, "AXTitle"), desc: str(e, "AXDescription"), ident: str(e, "AXIdentifier"), value: str(e, "AXValue")))
        for c in kids(e) { walk(c, d + 1) }
    }
    walk(AXUIElementCreateApplication(app.processIdentifier), 0)
    return out
}

func buttons(_ bid: String) -> [Node] { collect(bid).filter { $0.role == "AXButton" } }
func label(_ n: Node) -> String { n.desc.isEmpty ? n.title : n.desc }
func press(_ n: Node) -> Bool { AXUIElementPerformAction(n.el, "AXPress" as CFString) == .success }

func findButton(_ bid: String, _ pred: (Node) -> Bool) -> Node? { buttons(bid).first(where: pred) }
func waitFor<T>(_ sec: Double, _ f: () -> T?) -> T? {
    let end = Date().addingTimeInterval(sec)
    while Date() < end { if let v = f() { return v }; Thread.sleep(forTimeInterval: 0.15) }
    return nil
}
func fail(_ msg: String, _ code: Int32) -> Never { FileHandle.standardError.write((msg + "\n").data(using: .utf8)!); exit(code) }

let KEYALIAS: [Character: [String]] = ["*": ["별", "*", "star", "Star"], "#": ["우물 정자", "#", "pound", "Pound"]]
func keyNames(_ k: Character) -> [String] { KEYALIAS[k] ?? [String(k)] }
// 통화 중 배너 키패드의 버튼 이름은 "1,  "·"2, ABC"·"0, +" 처럼 "숫자, 글자" 형태다 → 쉼표 앞 머리말로 비교
func isKey(_ n: Node, _ k: Character) -> Bool {
    let l = label(n); let head = l.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? l
    return keyNames(k).contains(l) || keyNames(k).contains(head)
}

// 통화 중 배너(알림 센터)에 있는 종료·키패드·음소거 버튼 이름 후보 (한국어·영어)
let END = ["통화 종료", "종료", "끊기", "End", "end", "Hang Up", "hang up", "End Call"]
let KEYPAD = ["키패드", "Keypad", "keypad"]

func incallState() -> (Bool, [String]) {
    let labels = buttons(NC).map(label)
    let incall = labels.contains { l in END.contains(l) } || labels.contains { l in KEYPAD.contains(l) }
    return (incall, labels)
}

func dump(_ bid: String) {
    guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bid }) else { fail("앱 없음 \(bid)", 3) }
    func w(_ e: AXUIElement, _ d: Int) {
        if d > 18 { return }
        let r = str(e, "AXRole"); if r == "AXMenuBar" { return }
        print(String(repeating: "  ", count: d) + r + " [" + str(e, "AXTitle") + "|" + str(e, "AXDescription") + "|" + str(e, "AXIdentifier") + "|" + str(e, "AXValue") + "]")
        for c in kids(e) { w(c, d + 1) }
    }
    w(AXUIElementCreateApplication(app.processIdentifier), 0)
}

let a = CommandLine.arguments
guard a.count >= 2 else { fail("usage: phonectl dial|dtmf|hangup|state|dump", 2) }
guard AXIsProcessTrusted() else { fail("기기 제어(손쉬운 사용) 권한 없음", 3) }

func openPhone() {                     // 전화 앱이 꺼져 있으면 뒤에서 띄우고 창이 잡힐 때까지 기다린다
    if NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == PHONE }) == nil {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/open"); p.arguments = ["-g", "-a", "Phone"]; try? p.run(); p.waitUntilExit()
    }
    guard waitFor(8, { collect(PHONE).isEmpty ? nil : true }) != nil else { fail("전화 앱 창 없음", 3) }
}

switch a[1] {
case "dump":
    dump(a.count > 2 ? a[2] : PHONE)

case "state":
    let (inc, labels) = incallState()
    print(inc ? "incall" : "idle", labels.joined(separator: ","))

case "dial":
    guard a.count > 2 else { fail("번호 필요", 2) }
    let want = a[2].filter { "0123456789*#".contains($0) }
    guard !want.isEmpty else { fail("번호가 비었음", 2) }
    openPhone()
    func field() -> Node? { collect(PHONE).first { $0.ident == "PhoneNumberLabel" } }
    if field() == nil {
        guard let kp = waitFor(5, { findButton(PHONE) { label($0) == "키패드" } }) else { fail("키패드 버튼 못 찾음", 4) }
        _ = press(kp)
        guard waitFor(5, { field() }) != nil else { fail("키패드 화면 안 열림", 3) }
    }
    // 남은 입력 지우기 (지우기 버튼 이름은 환경마다 다를 수 있어 후보로 찾는다)
    var guardN = 0
    while let f = field(), !f.value.filter({ "0123456789*#".contains($0) }).isEmpty, guardN < 30 {
        guard let del = findButton(PHONE, { ["삭제", "지우기", "Delete", "delete", "뒤로 지우기"].contains(label($0)) }) else { fail("입력창이 비어 있지 않고 지우기 버튼도 못 찾음: \(f.value)", 5) }
        _ = press(del); guardN += 1; Thread.sleep(forTimeInterval: 0.08)
    }
    func digits() -> String { (field()?.value ?? "").filter { "0123456789*#".contains($0) } }
    Thread.sleep(forTimeInterval: 0.5)                           // 키패드 화면 전환이 끝나기를 기다린다 (첫 키가 씹히는 것 방지)
    for k in want {
        let before = digits().count
        var tries = 0
        while digits().count == before && tries < 3 {            // 키가 입력창에 반영될 때까지 확인하며 누른다
            guard let b = waitFor(3, { findButton(PHONE) { keyNames(k).contains(label($0)) && $0.role == "AXButton" } }) else { fail("키 \(k) 못 찾음", 4) }
            guard press(b) else { fail("키 \(k) 누르기 실패", 4) }
            _ = waitFor(1.0, { digits().count > before ? true : nil }); tries += 1
        }
    }
    let got = digits()
    guard got == want else { fail("입력값 불일치: 기대 \(want) / 실제 \(got) — 걸지 않음", 5) }
    guard let call = findButton(PHONE, { label($0) == "통화" || $0.desc == "응답" }) else { fail("통화 버튼 못 찾음", 4) }
    guard press(call) else { fail("통화 누르기 실패", 4) }
    print("OK dial \(want)")

case "dtmf":
    guard a.count > 2 else { fail("키 필요", 2) }
    var opened = false
    for k in a[2] where "0123456789*#".contains(k) {
        var b = findButton(NC) { isKey($0, k) }
        if b == nil && !opened {                                 // 통화 중 키패드가 아직 안 열렸다 → 한 번 연다
            if let kp = findButton(NC, { KEYPAD.contains(label($0)) }) { _ = press(kp); opened = true; Thread.sleep(forTimeInterval: 0.4) }
            b = waitFor(2, { findButton(NC) { isKey($0, k) } })
        }
        guard let btn = b else {
            fputs("--- 알림 센터 AX ---\n", stderr); dump(NC); fail("통화 중 키 \(k) 버튼 못 찾음", 4)
        }
        guard press(btn) else { fail("키 \(k) 누르기 실패", 4) }
        Thread.sleep(forTimeInterval: 0.12)
    }
    print("OK dtmf \(a[2])")

case "hangup":
    if let e = findButton(NC, { END.contains(label($0)) }) { print(press(e) ? "OK hangup" : "FAIL"); }
    else { fputs("--- 알림 센터 AX ---\n", stderr); dump(NC); fail("종료 버튼 못 찾음", 4) }

case "mic", "out":          // 전화 앱 오디오 메뉴에서 장치 선택: phonectl mic "BlackHole 16ch" / phonectl mic "시스템 설정값 사용"
    guard a.count > 2 else { fail("장치 이름 필요", 2) }
    openPhone()
    guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == PHONE }) else { fail("전화 앱 없음", 3) }
    let root = AXUIElementCreateApplication(app.processIdentifier)
    guard let (audio, menu) = waitFor(6, { () -> (AXUIElement, AXUIElement)? in   // 앱이 막 떴으면 메뉴 막대가 늦게 만들어진다
        guard let bar = attr(root, "AXMenuBar").map({ $0 as! AXUIElement }),
              let audio = kids(bar).first(where: { str($0, "AXTitle") == "오디오" }), let menu = kids(audio).first else { return nil }
        return (audio, menu)
    }) else { fail("오디오 메뉴 없음", 4) }
    let header = a[1] == "mic" ? "마이크" : "출력"
    func item() -> AXUIElement? {           // 누를 때마다 메뉴를 새로 읽는다 (막 뜬 앱은 항목이 바뀐다)
        let items = kids(kids(audio).first ?? menu)
        guard let h = items.firstIndex(where: { str($0, "AXTitle") == header }) else { return nil }
        return items[(h + 1)...].first { str($0, "AXTitle") == a[2] }
    }
    guard waitFor(4, { item() }) != nil else { fail("장치 못 찾음: \(a[2])", 4) }
    var ok = false
    for _ in 0..<3 where !ok {              // 체크 표시로 실제 선택을 확인한다
        if let it = item() { AXUIElementPerformAction(it, "AXPress" as CFString) }
        ok = waitFor(2, { (item().map { !str($0, "AXMenuItemMarkChar").isEmpty } ?? false) ? true : nil }) != nil
    }
    guard ok else { fail("선택 확인 실패: \(a[2])", 4) }
    print("OK \(a[1]) \(a[2])")

default:
    fail("unknown command", 2)
}
