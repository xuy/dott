import SwiftUI

@main
struct DottApp: App {
    @StateObject private var capture = MeetingCapture()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(capture: capture)
        } label: {
            // Single glyph, no text -- stays unremarkable if this screen
            // (menu bar included) is ever what's being shared in a meeting.
            Image(systemName: glyphName)
                .font(.system(size: 10))
        }
        .menuBarExtraStyle(.menu)
    }

    private var glyphName: String {
        if capture.isRecording { return "circle.fill" }
        if capture.isTranscribing { return "circle.dotted" }
        return "circle"
    }
}

struct MenuContent: View {
    @ObservedObject var capture: MeetingCapture

    var body: some View {
        if capture.isRecording {
            Text("Recording \u{2014} \(capture.elapsedString)")
            Button("Stop Recording") {
                capture.stop()
            }
        } else {
            Button("Start Recording") {
                capture.start()
            }
            if capture.isTranscribing {
                Text("Transcribing\u{2026}")
            }
            if let error = capture.lastError {
                Text(error)
                    .foregroundStyle(.red)
            }
        }
        Divider()
        if let transcriptPath = capture.lastTranscriptPath {
            Button("Open Last Transcript") {
                NSWorkspace.shared.open(transcriptPath)
            }
        }
        if let sessionDir = capture.lastSessionDir {
            Button("Reveal Last Recording") {
                NSWorkspace.shared.activateFileViewerSelecting([sessionDir])
            }
        }
        Button("Open Recordings Folder") {
            NSWorkspace.shared.open(MeetingCapture.recordingsRoot)
        }
        Divider()
        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
    }
}
