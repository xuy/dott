import SwiftUI

@main
struct RecorderApp: App {
    @StateObject private var capture = MeetingCapture()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(capture: capture)
        } label: {
            Text(capture.isRecording ? "\u{25CF} \(capture.elapsedString)" : "\u{25CB} Rec")
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
