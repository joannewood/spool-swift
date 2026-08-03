import SpoolCore
import SwiftUI

private enum AdminSection: String, CaseIterable, Identifiable {
    case archives, duplicates, suggestions, status

    var id: String { rawValue }

    var title: String {
        switch self {
        case .archives: return "Archives"
        case .duplicates: return "Duplicates"
        case .suggestions: return "Suggestions"
        case .status: return "Status"
        }
    }

    var icon: String {
        switch self {
        case .archives: return "archivebox"
        case .duplicates: return "square.on.square"
        case .suggestions: return "sparkles"
        case .status: return "heart.text.square"
        }
    }
}

struct AdminView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @StateObject private var viewModel: AdminViewModel
    @Environment(\.dismiss) private var dismiss
    // Optional, not `AdminSection` — mirrors `ContentView`'s main sidebar exactly.
    // The non-optional-selection form of `List(data, selection:)` this used to use
    // type-checks fine but its click-to-select silently does nothing on this SDK
    // (confirmed live: every row except the toolbar's unrelated Close button was
    // inert) — switching to the same Optional-selection, content-builder `List`
    // shape the main sidebar already uses (and which does work) sidesteps it.
    @State private var selection: AdminSection? = .archives
    @State private var showingDeleteAllDuplicatesConfirmation = false
    @State private var checkedRelationshipIds: Set<Int64> = []
    @State private var checkedProjectMembershipKeys: Set<String> = []
    @State private var checkedArchiveIds: Set<Int64> = []

    init(environment: AppEnvironment) {
        _viewModel = StateObject(wrappedValue: AdminViewModel(environment: environment))
    }

    var body: some View {
        NavigationSplitView {
            // A sidebar list of named sections with badge counts — the same "pick a
            // pane" shape as macOS System Settings — rather than one Form that grows
            // to a full-page scroll as more review queues get added.
            // Plain `Button` rows setting `selection` directly, not `List`'s own
            // `selection:` binding + `.tag()` — that binding-based approach (matching
            // ContentView's own, working, main sidebar exactly) still left every row
            // inert here even after being rewritten to match it. Whatever the actual
            // cause (this window is a secondary `Window` scene rather than the main
            // `WindowGroup`; possibly an SDK-specific regression), a `Button`'s action
            // always fires on click — there's no separate selection-binding plumbing
            // left that can silently fail. `.listRowBackground` stands in by hand for
            // the highlight `List(selection:)` would otherwise draw automatically.
            List {
                ForEach(AdminSection.allCases) { section in
                    Button {
                        selection = section
                    } label: {
                        Label(section.title, systemImage: section.icon)
                    }
                    .buttonStyle(.plain)
                    .badge(badgeCount(for: section) ?? 0)
                    .listRowBackground(
                        (selection ?? .archives) == section
                            ? Color.accentColor.opacity(0.25)
                            : Color.clear
                    )
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(180)
        } detail: {
            Form {
                switch selection ?? .archives {
                case .archives:
                    if !viewModel.pendingArchives.isEmpty { pendingArchivesSection }
                    if !viewModel.unsupportedArchives.isEmpty { unsupportedArchivesSection }
                    if !viewModel.rejectedArchives.isEmpty { rejectedArchivesSection }
                    if viewModel.pendingArchives.isEmpty && viewModel.unsupportedArchives.isEmpty && viewModel.rejectedArchives.isEmpty {
                        emptyState("No archives need review right now.")
                    }
                case .duplicates:
                    if !viewModel.duplicateGroups.isEmpty {
                        duplicatesSection
                    } else {
                        emptyState("No duplicate files found.")
                    }
                case .suggestions:
                    if !viewModel.suggestedRelationships.isEmpty { suggestedRelationshipsSection }
                    if !viewModel.suggestedProjectMemberships.isEmpty { suggestedProjectsSection }
                    if viewModel.suggestedRelationships.isEmpty && viewModel.suggestedProjectMemberships.isEmpty {
                        emptyState("No suggestions to review right now.")
                    }
                case .status:
                    statusSection
                }
            }
            .formStyle(.grouped)
            .navigationTitle((selection ?? .archives).title)
        }
        .toolbar {
            if selection == .status {
                ToolbarItem {
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await viewModel.loadStatus() } }
                        .help("Refresh queue and activity")
                }
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
        }
        .task { await viewModel.load() }
        .task(id: selection) {
            if selection == .status { await viewModel.loadStatus() }
        }
        // See SettingsView's identical fix — `.constant()` here is a real, confirmed
        // trigger for "Publishing changes from within view updates is not allowed".
        .alert("Error", isPresented: Binding(
            get: { viewModel.lastError != nil },
            set: { if !$0 { viewModel.lastError = nil } }
        ), actions: {
            Button("OK") { viewModel.lastError = nil }
        }, message: { Text(viewModel.lastError ?? "") })
        .frame(minWidth: 640, minHeight: 480)
    }

    private func badgeCount(for section: AdminSection) -> Int? {
        switch section {
        case .archives: return viewModel.pendingArchives.count
        case .duplicates: return viewModel.duplicateGroups.count
        case .suggestions: return viewModel.suggestedRelationships.count + viewModel.suggestedProjectMemberships.count
        case .status: return nil
        }
    }

    private var statusSection: some View {
        Group {
            if let totals = viewModel.ingestionTotals {
                Section("Library") {
                    LabeledContent("Total Files", value: "\(totals.totalFiles)")
                    LabeledContent("Rendered", value: "\(totals.renderDone)")
                    LabeledContent("Pending Render", value: "\(totals.renderPending)")
                    if totals.renderFailed > 0 {
                        LabeledContent("Failed Render", value: "\(totals.renderFailed)").foregroundStyle(.red)
                    }
                    if totals.unhashed > 0 {
                        LabeledContent("Not Yet Hashed", value: "\(totals.unhashed)")
                    }
                }
            }
            Section("Job Queue") {
                if viewModel.jobQueueCounts.isEmpty {
                    Text("Idle — nothing queued or running.").foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.jobQueueCounts) { count in
                        LabeledContent("\(jobTypeLabel(count.jobType)) (\(count.status.rawValue))", value: "\(count.count)")
                    }
                }
            }
            if !viewModel.runningJobs.isEmpty {
                Section("Running Now") {
                    ForEach(viewModel.runningJobs) { job in
                        HStack {
                            Text(jobTypeLabel(job.jobType))
                            Spacer()
                            Text(job.targetName ?? "—").foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
            Section("Recent Activity") {
                if viewModel.recentActivity.isEmpty {
                    Text("Nothing has finished yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.recentActivity) { activity in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Image(systemName: activity.status == .done ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(activity.status == .done ? .green : .red)
                                Text(jobTypeLabel(activity.jobType))
                                Spacer()
                                Text(activity.targetName ?? "—").foregroundStyle(.secondary).lineLimit(1)
                            }
                            if let error = activity.error {
                                Text(error).font(.caption2).foregroundStyle(.red).lineLimit(2)
                            }
                        }
                    }
                }
            }
        }
    }

    private func jobTypeLabel(_ type: JobType) -> String {
        switch type {
        case .ingest: return "Ingest"
        case .render: return "Render"
        case .renderStep: return "STEP Render"
        case .rescan: return "Rescan"
        case .extractZip: return "Extract Archive"
        }
    }

    private func emptyState(_ message: String) -> some View {
        Section {
            Text(message).foregroundStyle(.secondary)
        }
    }

    private var duplicatesSection: some View {
        Section("Duplicate Files (\(viewModel.duplicateGroups.count))") {
            ForEach(viewModel.duplicateGroups) { group in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(group.files.count) copies").font(.caption).foregroundStyle(.secondary)
                    ForEach(group.files) { file in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(file.displayName ?? file.filename)
                                Text(file.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Button("Delete", role: .destructive) { Task { await viewModel.deleteDuplicate(file) } }
                        }
                    }
                }
            }
            Button("Delete All Extra Copies…", role: .destructive) { showingDeleteAllDuplicatesConfirmation = true }
                .confirmationDialog(
                    "Delete every extra copy across all \(viewModel.duplicateGroups.count) duplicate groups?",
                    isPresented: $showingDeleteAllDuplicatesConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Delete All", role: .destructive) { Task { await viewModel.deleteAllDuplicates() } }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Keeps one copy per group — the oldest, or the one in your read-only Library folder if there is one — and moves every other copy to the Trash.")
                }
        }
    }

    private var suggestedRelationshipsSection: some View {
        Section("Suggested Relationships (\(viewModel.suggestedRelationships.count))") {
            ForEach(viewModel.suggestedRelationships, id: \.relationship.id) { pair in
                HStack {
                    Toggle("", isOn: checkedBinding(pair.relationship.id, in: $checkedRelationshipIds)).labelsHidden()
                    Text("\(pair.fromFile.filename) \(pair.relationship.type.rawValue.replacingOccurrences(of: "_", with: " ")) \(pair.toFile.filename)")
                        .lineLimit(1)
                        .suggestionTint()
                    Spacer()
                    ConfirmRejectButtons(
                        onConfirm: { Task { await viewModel.confirmRelationship(pair.relationship) } },
                        onReject: { Task { await viewModel.rejectRelationship(pair.relationship) } }
                    )
                }
            }
            BulkActionBar(
                totalCount: viewModel.suggestedRelationships.count,
                selectedCount: checkedRelationshipIds.count,
                allSelected: !viewModel.suggestedRelationships.isEmpty && checkedRelationshipIds.count == viewModel.suggestedRelationships.count,
                onToggleSelectAll: { checkedRelationshipIds = $0 ? Set(viewModel.suggestedRelationships.compactMap(\.relationship.id)) : [] },
                onConfirmSelected: {
                    Task {
                        await viewModel.confirmSelectedRelationships(ids: checkedRelationshipIds)
                        checkedRelationshipIds = []
                    }
                },
                onConfirmAll: { Task { await viewModel.confirmAllRelationships(); checkedRelationshipIds = [] } }
            )
        }
    }

    private var suggestedProjectsSection: some View {
        Section("Suggested Projects (\(viewModel.suggestedProjectMemberships.count))") {
            ForEach(viewModel.suggestedProjectMemberships) { entry in
                HStack {
                    Toggle("", isOn: checkedBinding(entry.id, in: $checkedProjectMembershipKeys)).labelsHidden()
                    Text("\(entry.file.filename) → \(entry.project.name)").lineLimit(1).suggestionTint()
                    Spacer()
                    ConfirmRejectButtons(
                        onConfirm: { Task { await viewModel.confirmProjectMembership(entry.membership) } },
                        onReject: { Task { await viewModel.rejectProjectMembership(entry.membership) } }
                    )
                }
            }
            BulkActionBar(
                totalCount: viewModel.suggestedProjectMemberships.count,
                selectedCount: checkedProjectMembershipKeys.count,
                allSelected: !viewModel.suggestedProjectMemberships.isEmpty && checkedProjectMembershipKeys.count == viewModel.suggestedProjectMemberships.count,
                onToggleSelectAll: { checkedProjectMembershipKeys = $0 ? Set(viewModel.suggestedProjectMemberships.map(\.id)) : [] },
                onConfirmSelected: {
                    let pairs = viewModel.suggestedProjectMemberships
                        .filter { checkedProjectMembershipKeys.contains($0.id) }
                        .map { (projectId: $0.membership.projectId, fileId: $0.membership.fileId) }
                    Task {
                        await viewModel.confirmSelectedProjectMemberships(pairs)
                        checkedProjectMembershipKeys = []
                    }
                },
                onConfirmAll: { Task { await viewModel.confirmAllProjectMemberships(); checkedProjectMembershipKeys = [] } }
            )
        }
    }

    private var pendingArchivesSection: some View {
        Section("Pending Archives (\(viewModel.pendingArchives.count))") {
            ForEach(viewModel.pendingArchives) { zip in
                HStack {
                    Toggle("", isOn: checkedBinding(zip.id, in: $checkedArchiveIds)).labelsHidden()
                    VStack(alignment: .leading) {
                        Text(zip.filename)
                        Text(zip.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    ConfirmRejectButtons(
                        confirmHelp: "Extract into this folder (deletes the original archive)",
                        rejectHelp: "Ignore this archive",
                        onConfirm: { Task { await viewModel.confirmArchive(zip) } },
                        onReject: { Task { await viewModel.rejectArchive(zip) } }
                    )
                }
            }
            BulkActionBar(
                totalCount: viewModel.pendingArchives.count,
                selectedCount: checkedArchiveIds.count,
                allSelected: !viewModel.pendingArchives.isEmpty && checkedArchiveIds.count == viewModel.pendingArchives.count,
                onToggleSelectAll: { checkedArchiveIds = $0 ? Set(viewModel.pendingArchives.compactMap(\.id)) : [] },
                onConfirmSelected: {
                    Task {
                        await viewModel.confirmSelectedArchives(ids: checkedArchiveIds)
                        checkedArchiveIds = []
                    }
                },
                onConfirmAll: { Task { await viewModel.confirmAllArchives(); checkedArchiveIds = [] } }
            )
            Text("Confirming extracts the archive into its folder and deletes the original — there's no undo. If you're not sure, reject it (you can always un-reject it below).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func checkedBinding<Key: Hashable>(_ key: Key?, in set: Binding<Set<Key>>) -> Binding<Bool> {
        Binding(
            get: { key.map { set.wrappedValue.contains($0) } ?? false },
            set: { isChecked in
                guard let key else { return }
                if isChecked { set.wrappedValue.insert(key) } else { set.wrappedValue.remove(key) }
            }
        )
    }

    private var unsupportedArchivesSection: some View {
        Section("Archives Spool Can't Inspect (\(viewModel.unsupportedArchives.count))") {
            ForEach(viewModel.unsupportedArchives) { zip in
                Text(zip.filename).lineLimit(1)
            }
            Text("Install `unar` (`brew install unar`) to let Spool look inside .7z/.rar archives for 3D-printing files.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var rejectedArchivesSection: some View {
        Section("Rejected Archives (\(viewModel.rejectedArchives.count))") {
            ForEach(viewModel.rejectedArchives) { zip in
                HStack {
                    Text(zip.filename).lineLimit(1)
                    Spacer()
                    Button { Task { await viewModel.unrejectArchive(zip) } } label: {
                        Image(systemName: "arrow.uturn.backward.circle")
                    }
                    .buttonStyle(.plain)
                    .help("Un-reject — move back to Pending Archives")
                    .accessibilityLabel("Un-reject \(zip.filename)")
                }
            }
        }
    }
}

/// "Select all"/"Confirm Selected"/"Confirm All" row shared by every bulk-review queue
/// (suggested relationships, suggested projects, pending archives) — matches the
/// source app's own accept-bulk/accept-all pattern: a checked-off subset for a
/// deliberate partial review, or one server-side sweep of everything when the intent
/// is just "yes, all of them."
private struct BulkActionBar: View {
    let totalCount: Int
    let selectedCount: Int
    let allSelected: Bool
    let onToggleSelectAll: (Bool) -> Void
    let onConfirmSelected: () -> Void
    let onConfirmAll: () -> Void

    var body: some View {
        HStack {
            Toggle("Select All", isOn: Binding(get: { allSelected }, set: onToggleSelectAll))
                .toggleStyle(.checkbox)
            Spacer()
            Button("Confirm Selected (\(selectedCount))", action: onConfirmSelected)
                .disabled(selectedCount == 0)
            Button("Confirm All (\(totalCount))", action: onConfirmAll)
                .disabled(totalCount == 0)
        }
        .font(.caption)
        .padding(.top, 2)
    }
}

/// A confirm (tick) / reject (x) icon-button pair — the shared shape of every
/// suggestion/archive review row, replacing verbose "Confirm"/"Reject" text buttons.
struct ConfirmRejectButtons: View {
    var confirmHelp: String = "Confirm"
    var rejectHelp: String = "Reject"
    let onConfirm: () -> Void
    let onReject: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onConfirm) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            .buttonStyle(.plain)
            .help(confirmHelp)
            .accessibilityLabel(confirmHelp)
            Button(action: onReject) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help(rejectHelp)
            .accessibilityLabel(rejectHelp)
        }
        .font(.title3)
    }
}

/// Visually distinguishes a not-yet-reviewed suggestion from confirmed data elsewhere
/// in the UI — an accent tint rather than plain primary text.
extension View {
    func suggestionTint() -> some View { foregroundStyle(Color.accentColor) }
}
