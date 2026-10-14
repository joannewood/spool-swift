import SpoolCore
import SwiftUI

/// Sends a file to the Saddle & STEM print queue — tries the Ranch directly first (or
/// whichever endpoint last worked), falls back to the classroom relay, matching whichever
/// network this iPad is actually reachable from right now. See `PrintQueueSettings` for
/// why there's no remembered student name here: these iPads are shared, so it's typed
/// fresh on every send.
struct SendToPrintQueueView: View {
    let file: SpoolFile
    let localFileURL: URL
    @EnvironmentObject private var settings: PrintQueueSettings
    @StateObject private var viewModel = SendToPrintQueueViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Your name", text: $viewModel.studentName)
                        .textInputAutocapitalization(.words)
                        .disableAutocorrection(true)
                } header: {
                    Text("Student name")
                } footer: {
                    Text("Typed fresh each time — this iPad is shared with other students.")
                }
                Section("Notes (optional)") {
                    TextField("Anything the teacher should know", text: $viewModel.notes, axis: .vertical)
                }
                if let successMessage = viewModel.successMessage {
                    Section {
                        Label(successMessage, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
            }
            .navigationTitle("Send to Print Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if viewModel.isSending {
                        ProgressView()
                    } else {
                        Button("Send") {
                            Task { await viewModel.send(file: file, localFileURL: localFileURL, settings: settings) }
                        }
                        .disabled(viewModel.studentName.trimmingCharacters(in: .whitespaces).isEmpty || viewModel.successMessage != nil)
                    }
                }
            }
            .alert("Couldn't Send", isPresented: Binding(
                get: { viewModel.lastError != nil },
                set: { if !$0 { viewModel.lastError = nil } }
            )) {
                Button("OK") { viewModel.lastError = nil }
            } message: {
                Text(viewModel.lastError ?? "")
            }
        }
    }
}

@MainActor
final class SendToPrintQueueViewModel: ObservableObject {
    @Published var studentName: String = ""
    @Published var notes: String = ""
    @Published var isSending = false
    @Published var lastError: String?
    @Published var successMessage: String?

    func send(file: SpoolFile, localFileURL: URL, settings: PrintQueueSettings) async {
        let trimmedName = studentName.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else {
            lastError = "Enter your name first."
            return
        }

        if let size = (try? FileManager.default.attributesOfItem(atPath: localFileURL.path)[.size]) as? Int,
           size > PrintQueueClient.maxInlineFileBytes {
            lastError = PrintQueueClient.SendError.fileTooLarge(bytes: size).errorDescription
            return
        }

        let order = settings.candidateOrder
        guard !order.isEmpty else {
            lastError = PrintQueueClient.SendError.noEndpointsConfigured.errorDescription
            return
        }

        isSending = true
        defer { isSending = false }

        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        var lastFailureDescription: String?

        for endpoint in order {
            guard let url = settings.url(for: endpoint) else { continue }
            guard await PrintQueueClient.probe(url: url) else {
                lastFailureDescription = "Couldn't reach \(endpoint.displayName)."
                continue
            }
            do {
                let id = try await PrintQueueClient.submit(
                    fileURL: localFileURL,
                    fileName: file.filename,
                    title: file.displayName ?? file.filename,
                    studentName: trimmedName,
                    notes: trimmedNotes,
                    sourceIdentifier: "spoolpad://\(file.id ?? 0)/\(file.filename)",
                    endpointURL: url,
                    token: settings.token(for: endpoint)
                )
                settings.lastSuccessfulEndpoint = endpoint
                successMessage = "Sent to the \(endpoint.displayName) print queue (submission #\(id))."
                return
            } catch {
                lastFailureDescription = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                continue
            }
        }
        lastError = lastFailureDescription ?? "Couldn't send — nothing was reachable."
    }
}
