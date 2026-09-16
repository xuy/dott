import SwiftUI

@main
struct RecorderApp: App {
    @StateObject private var capture = MeetingCapture()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(capture: capture)
        } label: {
            // Single glyph, no text -- stays unremarkable if this screen
            // (menu bar included) is ever what's being shared in a meeting.
            Image(systemName: capture.isRecording ? "circle.fill" : "circle")
                .font(.system(size: 10))
        }
        .menuBarExtraStyle(.menu)
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
            if let error = capture.lastError {
                Text(error)
                    .foregroundStyle(.red)
            }
        }
        Divider()
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
