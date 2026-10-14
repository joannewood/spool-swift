import SwiftUI

/// Where a teacher sets up the two print-queue destinations this iPad can send to — the
/// Ranch directly, and a classroom relay machine. Each is optional independently (an iPad
/// that only ever visits the Ranch doesn't need a relay configured, and vice versa); see
/// `PrintQueueSettings.candidateOrder` for how an empty one is simply skipped at send time.
struct PrintQueueSettingsView: View {
    @EnvironmentObject private var settings: PrintQueueSettings
    @Environment(\.dismiss) private var dismiss
    @State private var testResults: [PrintQueueSettings.Endpoint: TestResult] = [:]

    private enum TestResult {
        case testing
        case reachable
        case unreachable
    }

    var body: some View {
        NavigationStack {
            Form {
                endpointSection(.ranch, url: $settings.ranchURL, token: $settings.ranchToken)
                endpointSection(.relay, url: $settings.relayURL, token: $settings.relayToken)
            }
            .navigationTitle("Print Queue Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func endpointSection(_ endpoint: PrintQueueSettings.Endpoint, url: Binding<String>, token: Binding<String>) -> some View {
        Section {
            TextField("Server URL (e.g. http://192.168.1.50:8123)", text: url)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
            SecureField("Access token", text: token)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
            testConnectionRow(endpoint)
        } header: {
            Text(endpoint.displayName)
        } footer: {
            Text(footerText(endpoint))
        }
    }

    private func footerText(_ endpoint: PrintQueueSettings.Endpoint) -> String {
        switch endpoint {
        case .ranch:
            return "The print queue's own address on the Ranch's network and its QUEUE_ACCESS_TOKEN. Used when this iPad is at the Ranch."
        case .relay:
            return "A classroom relay machine's address on that classroom's network and its RELAY_ACCESS_TOKEN. Used when this iPad is away from the Ranch."
        }
    }

    @ViewBuilder
    private func testConnectionRow(_ endpoint: PrintQueueSettings.Endpoint) -> some View {
        HStack {
            Button("Test Connection") {
                Task { await testConnection(endpoint) }
            }
            .disabled(settings.url(for: endpoint) == nil || testResults[endpoint] == .testing)
            Spacer()
            switch testResults[endpoint] {
            case .testing:
                ProgressView()
            case .reachable:
                Label("Reachable", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .unreachable:
                Label("Not reachable", systemImage: "xmark.circle.fill").foregroundStyle(.red)
            case nil:
                EmptyView()
            }
        }
    }

    private func testConnection(_ endpoint: PrintQueueSettings.Endpoint) async {
        guard let url = settings.url(for: endpoint) else { return }
        testResults[endpoint] = .testing
        let reachable = await PrintQueueClient.probe(url: url)
        testResults[endpoint] = reachable ? .reachable : .unreachable
    }
}
