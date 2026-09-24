import AVFoundation
import Combine
import CoreMedia
import Foundation
import ScreenCaptureKit

@MainActor
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
    @Published var calendarConnected = false
    @Published var calendarConnecting = false
    @Published var calendarError: String?
    @Published var autoEnrichCalendar: Bool {
        didSet { UserDefaults.standard.set(autoEnrichCalendar, forKey: "autoEnrichCalendar") }
    }

    @Published var autoRecordZoom: Bool {
        didSet { UserDefaults.standard.set(autoRecordZoom, forKey: "autoRecordZoom") }
    }

    private let zoomWatcher = ZoomWatcher()
    private var calendarOAuth: GoogleOAuth?
    private var calendarClient: GoogleCalendarClient?
    private var calendarObserver: NSObjectProtocol?

    static let setupGuideURL = repoRoot.appendingPathComponent("Dott/GoogleCalendarSetup.md")

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

    private static func existingPath(_ path: URL) -> URL? {
        FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    private static var calendarConfigURL: URL {
        let repoConfig = repoRoot.appendingPathComponent("Dott/google-oauth-client.json")
        if let repoConfig = existingPath(repoConfig) { return repoConfig }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/Dott/google-oauth-client.json")
    }

    private var stream: SCStream?
    private var systemAudioFile: AVAudioFile?
    private var micAudioFile: AVAudioFile?
    private var startDate: Date?
    private var timer: Timer?
    private var captureGeneration = 0
    private var isStarting = false

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
        if UserDefaults.standard.object(forKey: "autoEnrichCalendar") == nil {
            UserDefaults.standard.set(true, forKey: "autoEnrichCalendar")
        }
        autoEnrichCalendar = UserDefaults.standard.bool(forKey: "autoEnrichCalendar")
        super.init()
        setupCalendarOAuth()

        zoomWatcher.onCallStateChanged = { [weak self] callInfo in
            guard let self, self.autoRecordZoom else { return }
            if let callInfo {
                self.start(zoomCall: callInfo)
            } else {
                self.stop()
            }
        }
        zoomWatcher.start()
    }

    func connectCalendar() {
        calendarOAuth?.connect()
    }

    func disconnectCalendar() {
        calendarOAuth?.disconnect()
        calendarConnected = false
        calendarError = nil
    }

    private func setupCalendarOAuth() {
        let configURL = Self.calendarConfigURL
        guard let data = try? Data(contentsOf: configURL),
            let config = try? JSONDecoder().decode(GoogleOAuthConfiguration.self, from: data)
        else { return }
        let oauth = GoogleOAuth(configuration: config)
        calendarOAuth = oauth
        calendarClient = GoogleCalendarClient(configuration: config)
        calendarConnected = oauth.isConnected
        calendarObserver = NotificationCenter.default.addObserver(
            forName: GoogleOAuth.changedNotification, object: nil, queue: .main
        ) { [weak self, weak oauth] _ in
            self?.calendarConnected = oauth?.isConnected ?? false
            self?.calendarConnecting = oauth?.isConnecting ?? false
            self?.calendarError = oauth?.errorMessage
        }
    }

    func start() {
        start(zoomCall: nil)
    }

    private func start(zoomCall: ZoomCallInfo?) {
        guard !isRecording, !isStarting else { return }
        isStarting = true
        captureGeneration += 1
        let generation = captureGeneration
        lastError = nil
        Task {
            do {
                try await startCapture(zoomCall: zoomCall, generation: generation)
            } catch {
                await MainActor.run {
                    guard self.captureGeneration == generation else { return }
                    self.isStarting = false
                    self.lastError = "\(error.localizedDescription)"
                }
            }
        }
    }

    func stop() {
        guard isRecording || isStarting else { return }
        captureGeneration += 1
        isStarting = false
        guard let stream, let sessionDir = lastSessionDir else { return }
        Task {
            do {
                try await stream.stopCapture()
            } catch {
                NSLog("Error stopping capture: \(error)")
            }
            let endedAt = Date()
            let recordedStart = self.startDate ?? endedAt
            await MainActor.run {
                self.finishRecording()
                self.updateMetadataEnd(for: sessionDir, endedAt: endedAt)
            }
            if self.autoEnrichCalendar {
                await self.enrichCalendarMetadata(for: sessionDir, start: recordedStart, end: endedAt)
            }
            await MainActor.run { self.transcribe(sessionDir) }
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
        let stderrLock = NSLock()
        var stderrData = Data()
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            stderrLock.lock()
            stderrData.append(data)
            stderrLock.unlock()
        }

        // Apps launched from Finder/Spotlight/LaunchServices don't inherit
        // the shell's PATH, so `ffmpeg` (Homebrew, /opt/homebrew/bin) is
        // invisible to child processes unless we add it back explicitly.
        var environment = ProcessInfo.processInfo.environment
        let extraPaths = "/opt/homebrew/bin:/usr/local/bin"
        environment["PATH"] = extraPaths + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        process.environment = environment

        process.terminationHandler = { [weak self] proc in
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            stderrLock.lock()
            let errorData = stderrData
            stderrLock.unlock()
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

    private func startCapture(zoomCall: ZoomCallInfo?, generation: Int) async throws {
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

        let sessionDir = try makeSessionDir(title: zoomCall?.meetingTitle)

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
            guard self.captureGeneration == generation, self.isStarting else {
                Task { try? await stream.stopCapture() }
                return
            }
            let startDate = Date()
            self.systemAudioFile = systemAudioFile
            self.micAudioFile = micAudioFile
            self.stream = stream
            self.lastSessionDir = sessionDir
            self.startDate = startDate
            self.isStarting = false
            self.isRecording = true
            self.writeMetadata(for: sessionDir, zoomCall: zoomCall, startDate: startDate)
            self.startTimer()
        }
    }

    private func finishRecording() {
        stream = nil
        systemAudioFile = nil
        micAudioFile = nil
        isStarting = false
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

    private func makeSessionDir(title: String?) throws -> URL {
        let formatter = DateFormatter()
        // Millisecond precision, not just seconds: back-to-back meetings can
        // stop-then-start within the same second, and two sessions landing
        // on the same folder name would silently truncate the first one's
        // still-open audio files.
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        let timestamp = formatter.string(from: Date())
        let slug = ZoomCallInfo.folderSlug(for: title)
        let base = slug.map { "\(timestamp)_\($0)" } ?? timestamp
        var dir = Self.recordingsRoot.appendingPathComponent(base, isDirectory: true)
        var suffix = 0
        while FileManager.default.fileExists(atPath: dir.path) {
            suffix += 1
            dir = Self.recordingsRoot.appendingPathComponent("\(base)-\(suffix)", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        return dir
    }

    private func enrichCalendarMetadata(for sessionDir: URL, start: Date, end: Date) async {
        guard let calendarClient else { return }
        do {
                let events = try await calendarClient.events(
                    from: start.addingTimeInterval(-15 * 60),
                    to: end.addingTimeInterval(15 * 60)
                )
                let metadataURL = sessionDir.appendingPathComponent("metadata.json")
                guard var metadata = (try? Data(contentsOf: metadataURL)).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) else { return }
                let zoomTitle = metadata["meeting_title"] as? String
                switch CalendarMatcher.match(events: events, recordingStart: start, recordingEnd: end, zoomTitle: zoomTitle) {
                case .matched(let event, let confidence):
                    metadata["calendar"] = [
                        "status": "matched",
                        "provider": "google",
                        "calendar_id": event.calendarID,
                        "event_id": event.id,
                        "summary": event.summary,
                        "start": ISO8601DateFormatter().string(from: event.start),
                        "end": ISO8601DateFormatter().string(from: event.end),
                        "attendees": event.attendees.map { ["display_name": $0.displayName] },
                        "confidence": confidence,
                    ]
                    if zoomTitle == nil || zoomTitle == "" {
                        metadata["meeting_title"] = event.summary
                    }
                case .ambiguous:
                    metadata["calendar"] = ["status": "ambiguous", "provider": "google"]
                case .noMatch:
                    metadata["calendar"] = ["status": "no_match", "provider": "google"]
                }
                self.writeMetadataObject(metadata, to: metadataURL)
            } catch {
                self.calendarError = error.localizedDescription
                NSLog("Calendar enrichment unavailable: \(error.localizedDescription)")
            }
    }

    private func updateMetadataEnd(for sessionDir: URL, endedAt: Date) {
        let metadataURL = sessionDir.appendingPathComponent("metadata.json")
        guard var metadata = (try? Data(contentsOf: metadataURL)).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) else { return }
        metadata["ended_at"] = ISO8601DateFormatter().string(from: endedAt)
        writeMetadataObject(metadata, to: metadataURL)
    }

    private func writeMetadata(for sessionDir: URL, zoomCall: ZoomCallInfo?, startDate: Date) {
        let formatter = ISO8601DateFormatter()
        let metadata: [String: Any] = [
            "schema": 2,
            "session_id": sessionDir.lastPathComponent,
            "started_at": formatter.string(from: startDate),
            "source": zoomCall == nil ? "manual" : "zoom",
            "meeting_title": zoomCall?.meetingTitle ?? NSNull(),
        ]
        guard JSONSerialization.isValidJSONObject(metadata) else { return }
        let destination = sessionDir.appendingPathComponent("metadata.json")
        writeMetadataObject(metadata, to: destination)
    }

    private func writeMetadataObject(_ metadata: [String: Any], to destination: URL) {
        do {
            let data = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted])
            let temp = destination.appendingPathExtension("tmp")
            try data.write(to: temp, options: .atomic)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: destination)
            }
        } catch {
            NSLog("Could not write recording metadata: \(error)")
        }
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
