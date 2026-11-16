import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia
import CoreAudio
import AudioToolbox

// 통화 소리를 Deepgram 실시간 스트리밍으로 보내 글자를 한 줄씩 출력한다.
//   DEEPGRAM_API_KEY=... arsear <최대초> [살릴 앱 번들ID,...]
// 출력: "I|중간 결과" / "F|확정 결과"  (stdout, 즉시 flush)
// GUI 앱 소리는 모두 빼고(통화 중계 데몬 소리만 남김) 지정 앱만 살린다.

setvbuf(stdout, nil, _IOLBF, 0)
// PCMOUT: STT 없이 통화 소리 PCM을 표준출력으로 내보낸다 (GPT-Live 세션용). 상태 메시지는 표준에러로 돌린다.
let pcmFd: Int32 = CommandLine.arguments.contains { $0.contains("PCMOUT") } ? dup(1) : -1
if pcmFd >= 0 { dup2(2, 1) }
let outRate = Double(ProcessInfo.processInfo.environment["AICALL_RATE"] ?? "") ?? 16000
let args = CommandLine.arguments
let maxSec = Double(args.count > 1 ? args[1] : "120") ?? 120
let keep = Set((args.count > 2 ? args[2] : "com.apple.FaceTime").split(separator: ",").map(String.init))
let key = ProcessInfo.processInfo.environment["DEEPGRAM_API_KEY"] ?? ""
if key.isEmpty && pcmFd < 0 { print("E|no DEEPGRAM_API_KEY"); exit(2) }

var req = URLRequest(url: URL(string: "wss://api.deepgram.com/v1/listen?model=nova-3&language=ko&encoding=linear16&sample_rate=16000&channels=1&interim_results=true&endpointing=500&smart_format=true")!)
req.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
var levelPeak: Float = 0
let levelTimer = DispatchSource.makeTimerSource(queue: .main)
var ws = URLSession.shared.webSocketTask(with: req)
if pcmFd < 0 { ws.resume() }

// 연결이 끊기면 다시 붙는다 (통화 도중 끊기면 안내를 놓치므로)
func reconnect() {
    ws.cancel()
    ws = URLSession.shared.webSocketTask(with: req)
    ws.resume()
    print("E|reconnected")
    receive()
}

func receive() {
    let cur = ws
    cur.receive { r in
        if case .success(.string(let s)) = r,
           let d = s.data(using: .utf8),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let ch = j["channel"] as? [String: Any],
           let alts = ch["alternatives"] as? [[String: Any]],
           let t = alts.first?["transcript"] as? String, !t.isEmpty {
            let fin = (j["is_final"] as? Bool) ?? false
            print("\(fin ? "F" : "I")|\(t)")
        }
        if case .failure(let e) = r {
            print("E|ws \(e.localizedDescription)")
            if cur === ws { DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { reconnect() } }
            return
        }
        receive()
    }
}
if pcmFd < 0 { receive() }

final class Tap: NSObject, SCStreamOutput, SCStreamDelegate {
    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sb.isValid else { return }
        try? sb.withAudioBufferList { abl, _ in
            guard let fmt = sb.formatDescription.flatMap({ AVAudioFormat(cmAudioFormatDescription: $0) }),
                  let buf = AVAudioPCMBuffer(pcmFormat: fmt, bufferListNoCopy: abl.unsafePointer),
                  let src = buf.floatChannelData else { return }
            let n = Int(buf.frameLength)
            var pcm = [Int16](repeating: 0, count: n)
            for i in 0..<n { pcm[i] = Int16(max(-1, min(1, src[0][i])) * 32767); levelPeak = max(levelPeak, abs(src[0][i])) }
            let data = pcm.withUnsafeBufferPointer { Data(buffer: $0) }
            ws.send(.data(data)) { _ in }
        }
    }
    func stream(_ s: SCStream, didStopWithError e: Error) { print("E|stream \(e.localizedDescription)"); exit(9) }   // 엔진이 알아채고 다시 시작한다
}


// ---- 통화 소리 경로 (macOS 27 전화 앱): 통화 중계 데몬(avconferenced)의 출력만 프로세스 오디오 탭으로 잡는다.
// 화면 녹화(replayd)를 쓰지 않아 충돌이 없고, 다른 앱 소리가 섞이지 않는다. keep 인자에 "TAP"이 있으면 이 경로.
var tapRefs: [Any] = []
// 상대 목소리를 내 스피커로 들을지. 끄면 탭은 그대로 받으면서 스피커로만 안 나간다(mutedWhenTapped).
// 시작값은 환경변수 AICALL_HEAR(0=끔), 통화 중에는 SIGUSR1=끄기 / SIGUSR2=켜기.
var tapDesc: CATapDescription?
var tapObj = AudioObjectID(0)
func setHear(_ on: Bool) {
    guard let d = tapDesc, tapObj != 0 else { return }
    d.muteBehavior = on ? .unmuted : .mutedWhenTapped
    var a = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyDescription, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var ref: CATapDescription = d
    let st = withUnsafeMutablePointer(to: &ref) { AudioObjectSetPropertyData(tapObj, &a, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0) }
    FileHandle.standardError.write("S|hear \(on ? 1 : 0) \(st)\n".data(using: .utf8)!)
}
signal(SIGUSR1, SIG_IGN); signal(SIGUSR2, SIG_IGN)
let hearQ = DispatchQueue(label: "hear")
let hearOff = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: hearQ)
let hearOn = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: hearQ)
hearOff.setEventHandler { setHear(false) }; hearOn.setEventHandler { setHear(true) }
hearOff.resume(); hearOn.resume()
let pcmOut: FileHandle? = ProcessInfo.processInfo.environment["AICALL_PCM"].flatMap { FileManager.default.createFile(atPath: $0, contents: nil); return FileHandle(forWritingAtPath: $0) }
func startProcessTap() throws {
    let pg = Process(); pg.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep"); pg.arguments = ["-x", "avconferenced"]
    let pipe = Pipe(); pg.standardOutput = pipe; try pg.run(); pg.waitUntilExit()
    let txt = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard let pid = Int32(txt.split(separator: "\n").first ?? "") else { print("E|avconferenced 프로세스 없음"); exit(3) }
    var ta = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var q = pid; var obj = AudioObjectID(0); var osz = UInt32(4)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &ta, 4, &q, &osz, &obj) == noErr, obj != 0 else { print("E|오디오 프로세스 객체 없음"); exit(3) }
    let desc = CATapDescription(stereoMixdownOfProcesses: [obj]); desc.muteBehavior = ProcessInfo.processInfo.environment["AICALL_HEAR"] == "0" ? .mutedWhenTapped : .unmuted
    var tapID = AudioObjectID(0)
    var st = AudioHardwareCreateProcessTap(desc, &tapID)
    guard st == noErr else { print("E|탭 생성 실패 \(st)"); exit(3) }
    var fa = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var asbd = AudioStreamBasicDescription(); var fsz = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    AudioObjectGetPropertyData(tapID, &fa, 0, nil, &fsz, &asbd)
    guard let src = AVAudioFormat(streamDescription: &asbd),
          let dst = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: outRate, channels: 1, interleaved: true),
          let conv = AVAudioConverter(from: src, to: dst) else { print("E|오디오 변환기 실패"); exit(3) }
    let dict: [String: Any] = [kAudioAggregateDeviceNameKey: "aicall-tap", kAudioAggregateDeviceUIDKey: UUID().uuidString,
                               kAudioAggregateDeviceIsPrivateKey: true,
                               kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]]]
    var agg = AudioObjectID(0)
    st = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &agg)
    guard st == noErr else { print("E|집합 장치 실패 \(st)"); exit(4) }
    var proc: AudioDeviceIOProcID?
    st = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, nil) { _, inData, _, _, _ in
        let list = UnsafeMutablePointer(mutating: inData)
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: src, bufferListNoCopy: list) else { return }
        if let ch = inBuf.floatChannelData { for i in 0..<Int(inBuf.frameLength) { levelPeak = max(levelPeak, abs(ch[0][i])) } }
        let cap = AVAudioFrameCount(Double(inBuf.frameLength) * outRate / src.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: cap) else { return }
        var given = false
        conv.convert(to: out, error: nil) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true; status.pointee = .haveData; return inBuf
        }
        if out.frameLength > 0, let p = out.int16ChannelData {
            // 통화 소리는 작다(최대 0.06). 실통화 녹음 재현 시험에서 3배 증폭 + endpointing 500이 전화번호 숫자를 빠뜨리지 않았다
            for i in 0..<Int(out.frameLength) { p[0][i] = Int16(max(-32768, min(32767, Int32(p[0][i]) * 3))) }
            let chunk = Data(bytes: p[0], count: Int(out.frameLength) * 2)
            pcmOut?.write(chunk)
            if pcmFd >= 0 { chunk.withUnsafeBytes { _ = write(pcmFd, $0.baseAddress, $0.count) } } else { ws.send(.data(chunk)) { _ in } }
        }
    }
    guard st == noErr, let pr = proc else { print("E|IOProc 실패 \(st)"); exit(5) }
    AudioDeviceStart(agg, pr)
    tapRefs = [tapID, agg]; tapDesc = desc; tapObj = tapID
}

let tap = Tap()
Task {
    do {
        if keep.contains("STDIN") {                 // 연습 모드: 표준입력의 16kHz mono PCM(마이크)을 받아쓴다
            print("S|listening")
            levelTimer.schedule(deadline: .now() + 2, repeating: 2)
            levelTimer.setEventHandler { print("L|\(String(format: "%.3f", levelPeak))"); levelPeak = 0 }
            levelTimer.resume()
            Thread.detachNewThread {
                while true {
                    let d = FileHandle.standardInput.availableData
                    if d.isEmpty { exit(0) }
                    d.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
                        for x in b.bindMemory(to: Int16.self) { levelPeak = max(levelPeak, abs(Float(x) / 32768)) }
                    }
                    ws.send(.data(d)) { _ in }
                }
            }
            while true {
                try await Task.sleep(nanoseconds: 4_000_000_000)
                ws.send(.string("{\"type\":\"KeepAlive\"}")) { _ in }
            }
        }
        if keep.contains("TAP") {
            try startProcessTap()
            print("S|listening")
            levelTimer.schedule(deadline: .now() + 2, repeating: 2)
            levelTimer.setEventHandler { print("L|\(String(format: "%.3f", levelPeak))"); levelPeak = 0 }
            levelTimer.resume()
            let end = Date().addingTimeInterval(maxSec)
            while Date() < end {
                try await Task.sleep(nanoseconds: 4_000_000_000)
                if pcmFd < 0 { ws.send(.string("{\"type\":\"KeepAlive\"}")) { _ in } }
            }
            if pcmFd < 0 { ws.send(.string("{\"type\":\"CloseStream\"}")) { _ in } }
            try await Task.sleep(nanoseconds: 1_000_000_000)
            exit(0)
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let d = content.displays.first else { print("E|no display"); exit(3) }
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 16000
        cfg.channelCount = 1
        cfg.width = 2; cfg.height = 2
        let ex = keep.contains("ALL") ? [] : content.applications.filter { !keep.contains($0.bundleIdentifier) }   // ALL = 진단용: 아무 앱도 빼지 않는다
        let st = SCStream(filter: SCContentFilter(display: d, excludingApplications: ex, exceptingWindows: []),
                          configuration: cfg, delegate: tap)
        try st.addStreamOutput(tap, type: .audio, sampleHandlerQueue: DispatchQueue(label: "a"))
        try await st.startCapture()
        print("S|listening")
        levelTimer.schedule(deadline: .now() + 2, repeating: 2)
        levelTimer.setEventHandler { print("L|\(String(format: "%.3f", levelPeak))"); levelPeak = 0 }
        levelTimer.resume()
        // Deepgram은 10초 무음이면 끊으므로 KeepAlive를 보낸다
        let end = Date().addingTimeInterval(maxSec)
        while Date() < end {
            try await Task.sleep(nanoseconds: 4_000_000_000)
            ws.send(.string("{\"type\":\"KeepAlive\"}")) { _ in }
        }
        try await st.stopCapture()
        ws.send(.string("{\"type\":\"CloseStream\"}")) { _ in }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        exit(0)
    } catch { print("E|\(error.localizedDescription)"); exit(4) }
}
dispatchMain()
