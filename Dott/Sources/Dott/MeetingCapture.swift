import AVFoundation
import Combine
import CoreMedia
import Foundation
import ScreenCaptureKit

final class MeetingCapture: NSObject, ObservableObject {
    @Published var isRecording = false
    // A set, not a single Bool: back-to-back meetings can leave more than one
    // transcription running at once, and the UI shouldn't say "done" just
    // because the most-recently-started one finished first.
    @Published private var activeTranscriptions: Set<URL> = []
    var isTranscribing: Bool { !activeTranscriptions.isEmpty }
    @Published var elapsedString = "00:00"
    @Published var lastSessionDir: URL?
    @Published var lastTranscriptPath: URL?
    @Published var lastError: String?

    @Published var autoRecordZoom: Bool {
        didSet { UserDefaults.standard.set(autoRecordZoom, forKey: "autoRecordZoom") }
    }

    private let zoomWatcher = ZoomWatcher()

    static let recordingsRoot: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("MeetingRecordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // This is a personal single-machine tool, not a relocatable app -- these
    // paths point at the sibling `transcribe/` checkout that ships alongside
    // Dott's own source in ~/src/meeting-recorder. Update if you move it.
    private static let repoRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("src/meeting-recorder", isDirectory: true)
    private static let transcribePython = repoRoot
        .appendingPathComponent("transcribe/.venv/bin/python3")
    private static let transcribeScript = repoRoot
        .appendingPathComponent("transcribe/transcribe.py")

    private var stream: SCStream?
    private var systemAudioFile: AVAudioFile?
    private var micAudioFile: AVAudioFile?
    private var startDate: Date?
    private var timer: Timer?

    // Separate serial queues per output type: each queue only ever touches its
    // own AVAudioFile, so no locking is needed between them.
    private let systemQueue = DispatchQueue(label: "meeting.audio.system")
    private let micQueue = DispatchQueue(label: "meeting.audio.mic")

    override init() {
        // Default true: this is the feature that was actually asked for --
        // forgetting to stop/restart between back-to-back Zoom calls was
        // literally the motivating complaint.
        if UserDefaults.standard.object(forKey: "autoRecordZoom") == nil {
            UserDefaults.standard.set(true, forKey: "autoRecordZoom")
        }
        autoRecordZoom = UserDefaults.standard.bool(forKey: "autoRecordZoom")
        super.init()

        zoomWatcher.onCallStateChanged = { [weak self] inCall in
            guard let self, self.autoRecordZoom else { return }
            if inCall {
                self.start()
            } else {
                self.stop()
            }
        }
        zoomWatcher.start()
    }

    func start() {
        guard !isRecording else { return }
        lastError = nil
        Task {
            do {
                try await startCapture()
            } catch {
                await MainActor.run {
                    self.lastError = "\(error.localizedDescription)"
                }
            }
        }
    }

    func stop() {
        guard isRecording, let stream else { return }
        Task {
            do {
                try await stream.stopCapture()
            } catch {
                NSLog("Error stopping capture: \(error)")
            }
            await MainActor.run {
                let sessionDir = self.lastSessionDir
                self.finishRecording()
                if let sessionDir {
                    self.transcribe(sessionDir)
                }
            }
        }
    }

    private func transcribe(_ sessionDir: URL) {
        guard FileManager.default.fileExists(atPath: Self.transcribePython.path) else {
            lastError = "Transcription venv not found at \(Self.transcribePython.path)"
            return
        }
        activeTranscriptions.insert(sessionDir)
        lastError = nil

        let process = Process()
        process.executableURL = Self.transcribePython
        process.arguments = [Self.transcribeScript.path, sessionDir.path]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        // Apps launched from Finder/Spotlight/LaunchServices don't inherit
        // the shell's PATH, so `ffmpeg` (Homebrew, /opt/homebrew/bin) is
        // invisible to child processes unless we add it back explicitly.
        var environment = ProcessInfo.processInfo.environment
        let extraPaths = "/opt/homebrew/bin:/usr/local/bin"
        environment["PATH"] = extraPaths + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        process.environment = environment

        process.terminationHandler = { [weak self] proc in
            let errorData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            DispatchQueue.main.async {
                guard let self else { return }
                self.activeTranscriptions.remove(sessionDir)
                if proc.terminationStatus == 0 {
                    self.lastTranscriptPath = sessionDir.appendingPathComponent("transcript.md")
                } else {
                    let message = String(data: errorData, encoding: .utf8) ?? "unknown error"
                    self.lastError = "Transcription failed: \(message.suffix(200))"
                }
            }
        }

        do {
            try process.run()
        } catch {
            activeTranscriptions.remove(sessionDir)
            lastError = "Could not launch transcription: \(error.localizedDescription)"
        }
    }

    private func startCapture() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48_000
        config.channelCount = 1
        config.captureMicrophone = true
        config.excludesCurrentProcessAudio = true
        // We never register a `.screen` output, so keep the (unused) video
        // side of the stream as cheap as possible.
        config.width = 2
        config.height = 2
        config.showsCursor = false
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let sessionDir = try makeSessionDir()

        // AAC/m4a instead of float32 WAV: ~15-20x smaller on disk for
        // near-identical speech quality, and AVAudioFile encodes it directly
        // -- no separate encoder needed. Whisper (via ffmpeg) reads m4a fine.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ]
        let systemAudioFile = try AVAudioFile(
            forWriting: sessionDir.appendingPathComponent("system.m4a"), settings: settings)
        let micAudioFile = try AVAudioFile(
            forWriting: sessionDir.appendingPathComponent("mic.m4a"), settings: settings)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: systemQueue)
        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: micQueue)
        try await stream.startCapture()

        await MainActor.run {
            self.systemAudioFile = systemAudioFile
            self.micAudioFile = micAudioFile
            self.stream = stream
            self.lastSessionDir = sessionDir
            self.startDate = Date()
            self.isRecording = true
            self.startTimer()
        }
    }

    private func finishRecording() {
        stream = nil
        systemAudioFile = nil
        micAudioFile = nil
        isRecording = false
        timer?.invalidate()
        timer = nil
        elapsedString = "00:00"
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let start = self.startDate else { return }
            let elapsed = Int(Date().timeIntervalSince(start))
            self.elapsedString = String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
        }
    }

    private func makeSessionDir() throws -> URL {
        let formatter = DateFormatter()
        // Millisecond precision, not just seconds: back-to-back meetings can
        // stop-then-start within the same second, and two sessions landing
        // on the same folder name would silently truncate the first one's
        // still-open audio files.
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        let dir = Self.recordingsRoot.appendingPathComponent(
            formatter.string(from: Date()), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private enum CaptureError: LocalizedError {
        case noDisplay
        var errorDescription: String? {
            switch self {
            case .noDisplay: return "No display available to capture audio from."
            }
        }
    }
}

extension MeetingCapture: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("Stream stopped with error: \(error)")
        DispatchQueue.main.async { [weak self] in
            self?.finishRecording()
            self?.lastError = error.localizedDescription
        }
    }
}

extension MeetingCapture: SCStreamOutput {
    func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }
        guard let pcmBuffer = Self.pcmBuffer(from: sampleBuffer) else { return }

        switch type {
        case .audio:
            try? systemAudioFile?.write(from: pcmBuffer)
        case .microphone:
            try? micAudioFile?.write(from: pcmBuffer)
        default:
            break
        }
    }

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = sampleBuffer.formatDescription,
            var absd = formatDescription.audioStreamBasicDescription,
            let format = AVAudioFormat(streamDescription: &absd)
        else {
            return nil
        }

        var result: AVAudioPCMBuffer?
        try? sampleBuffer.withAudioBufferList { audioBufferList, _ in
            result = AVAudioPCMBuffer(
                pcmFormat: format, bufferListNoCopy: audioBufferList.unsafePointer)
        }
        return result
    }
}
