import AVFoundation
import Combine
import CoreMedia
import Foundation
import ScreenCaptureKit

final class MeetingCapture: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var elapsedString = "00:00"
    @Published var lastSessionDir: URL?
    @Published var lastError: String?

    static let recordingsRoot: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("MeetingRecordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private var stream: SCStream?
    private var systemAudioFile: AVAudioFile?
    private var micAudioFile: AVAudioFile?
    private var startDate: Date?
    private var timer: Timer?

    // Separate serial queues per output type: each queue only ever touches its
    // own AVAudioFile, so no locking is needed between them.
    private let systemQueue = DispatchQueue(label: "meeting.audio.system")
    private let micQueue = DispatchQueue(label: "meeting.audio.mic")

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
                self.finishRecording()
            }
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

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
        ]
        let systemAudioFile = try AVAudioFile(
            forWriting: sessionDir.appendingPathComponent("system.wav"), settings: settings)
        let micAudioFile = try AVAudioFile(
            forWriting: sessionDir.appendingPathComponent("mic.wav"), settings: settings)

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
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
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
