import SwiftUI

/// Your own status and location, and Portal's settings
struct YouView: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Relay", value: "Not Set Up")
                } header: {
                    Text("Relay")
                } footer: {
                    Text("Portal talks to VRChat through your own VRCX relay, so your VRChat password never leaves it.")
                }

                Section("About") {
                    LabeledContent("Version", value: BuildInfo.versionText)
                    if let commit = BuildInfo.commit {
                        LabeledContent("Commit", value: commit)
                            .textSelection(.enabled)
                    }
                }

                Section {
                } footer: {
                    Text("Portal is unofficial, and isn't made or endorsed by VRChat or the VRCX team.")
                }
            }
            .navigationTitle("You")
        }
    }
}
