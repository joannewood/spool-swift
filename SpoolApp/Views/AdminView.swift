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
    @State private var showingEmptyGroupSelectionWarning = false
    @State private var checkedRelationshipIds: Set<Int64> = []
    @State private var checkedProjectMembershipKeys: Set<String> = []
    @State private var checkedArchiveIds: Set<Int64> = []
    @State private var checkedRejectedArchiveIds: Set<Int64> = []
    @State private var checkedDuplicateFileIds: Set<Int64> = []
    // Window(id:) scenes on macOS keep this view (and its @StateObject) alive across
    // close/reopen — closing is just an NSWindow order-out, not a real teardown — so
    // `.task` (which only fires once per view identity) never refires on reopen and
    // the queues go stale. `controlActiveState` does track per-window key status
    // across that same close/reopen, so reloading on every transition to `.key`
    // covers both the very first open (paired with `.task` below) and every later
    // reopen or refocus.
    @Environment(\.controlActiveState) private var controlActiveState

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
        .onChange(of: controlActiveState) { _, newValue in
            guard newValue == .key else { return }
            Task { await viewModel.load() }
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

    /// Every duplicate file across every group, minus the ones Spool can never
    /// delete — "Select All"/"Delete Selected" only ever operate on files that could
    /// actually be deleted, same as the per-row Delete button already being disabled
    /// for a Library copy.
    private var deletableDuplicateFiles: [SpoolFile] {
        viewModel.duplicateGroups.flatMap(\.files).filter { !viewModel.libraryRootIds.contains($0.watchedRootId) }
    }

    /// Groups where the current manual checkbox selection covers every file in the
    /// group — i.e. "Delete Selected" would leave zero copies, not "all but one"
    /// like "Delete All Extra Copies" always guarantees. A group with any Library
    /// copy can never appear here, since a Library file's checkbox is disabled and
    /// so can never be part of the selection.
    private var duplicateGroupsFullyEmptiedBySelection: [DuplicateGroup] {
        viewModel.duplicateGroups.filter { group in
            !group.files.isEmpty && group.files.allSatisfy { checkedDuplicateFileIds.contains($0.id ?? -1) }
        }
    }

    private var duplicatesSection: some View {
        Section("Duplicate Files (\(viewModel.duplicateGroups.count))") {
            // Same "explain the destructive bulk action before the bar" placement as
            // `pendingArchivesSection` — but this queue needs it more: "Delete
            // Selected"/"Delete All" here are two different safety levels ("All"
            // always keeps one copy per group; "Selected" deletes exactly what's
            // checked, which *can* be every copy of a file if you check them all
            // yourself), not just two counts over the same underlying action like
            // every other queue's Selected/All pair.
            Text("\"Delete All Extra Copies\" always keeps one file per group — the oldest, or your Library copy. \"Delete Selected\" deletes exactly what you've checked, which can empty a group entirely if you check every copy yourself.")
                .font(.caption).foregroundStyle(.secondary)
            // Bar comes first, matching every other bulk-review queue — see
            // `suggestedRelationshipsSection`'s comment for why.
            BulkActionBar(
                totalCount: viewModel.duplicateFilesEligibleForAutoCleanup,
                selectedCount: checkedDuplicateFileIds.count,
                allSelected: !deletableDuplicateFiles.isEmpty && checkedDuplicateFileIds.count == deletableDuplicateFiles.count,
                actionLabel: "Delete",
                allActionLabel: "Delete All Extra Copies",
                destructive: true,
                onToggleSelectAll: { checkedDuplicateFileIds = $0 ? Set(deletableDuplicateFiles.compactMap(\.id)) : [] },
                onActionSelected: {
                    // Selecting every copy in a group is easy to do without meaning
                    // to (e.g. "Select All" across a library with one big group) —
                    // catch it here rather than silently leaving zero copies behind.
                    if !duplicateGroupsFullyEmptiedBySelection.isEmpty {
                        showingEmptyGroupSelectionWarning = true
                    } else {
                        let files = deletableDuplicateFiles.filter { checkedDuplicateFileIds.contains($0.id ?? -1) }
                        Task {
                            await viewModel.deleteSelectedDuplicates(files)
                            checkedDuplicateFileIds = []
                        }
                    }
                },
                onActionAll: { showingDeleteAllDuplicatesConfirmation = true }
            )
            .confirmationDialog(
                "Delete every extra copy across all \(viewModel.duplicateGroups.count) duplicate groups?",
                isPresented: $showingDeleteAllDuplicatesConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete All", role: .destructive) { Task { await viewModel.deleteAllDuplicates(); checkedDuplicateFileIds = [] } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Keeps one copy per group — the oldest, or the one in your read-only Library folder if there is one — and moves every other copy to the Trash.")
            }
            .confirmationDialog(
                duplicateGroupsFullyEmptiedBySelection.count == 1
                    ? "Delete every copy of this file?"
                    : "Delete every copy of \(duplicateGroupsFullyEmptiedBySelection.count) files?",
                isPresented: $showingEmptyGroupSelectionWarning,
                titleVisibility: .visible
            ) {
                Button("Delete Anyway", role: .destructive) {
                    let files = deletableDuplicateFiles.filter { checkedDuplicateFileIds.contains($0.id ?? -1) }
                    Task {
                        await viewModel.deleteSelectedDuplicates(files)
                        checkedDuplicateFileIds = []
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your selection includes every copy in \(duplicateGroupsFullyEmptiedBySelection.count == 1 ? "one group" : "\(duplicateGroupsFullyEmptiedBySelection.count) groups") — none would be left, unlike \"Delete All Extra Copies,\" which always keeps one. They'll still go to the Trash, so this is recoverable there.")
            }
            ForEach(viewModel.duplicateGroups) { group in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(group.files.count) copies").font(.caption).foregroundStyle(.secondary)
                    ForEach(group.files) { file in
                        HStack {
                            let isLocked = viewModel.libraryRootIds.contains(file.watchedRootId)
                            Toggle("", isOn: checkedBinding(file.id, in: $checkedDuplicateFileIds))
                                .labelsHidden()
                                .toggleStyle(.checkbox)
                                .disabled(isLocked)
                            VStack(alignment: .leading) {
                                HStack(spacing: 4) {
                                    Text(file.displayName ?? file.filename)
                                    // Confirmed live: no icon existed for this anywhere
                                    // in the app before — read-only status was text-only,
                                    // so a copy's undeletability only showed up *after*
                                    // clicking Delete and hitting the error.
                                    if isLocked {
                                        Image(systemName: "lock.fill")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .help("In your read-only Library folder — can't be deleted from Spool")
                                            .accessibilityLabel("Locked: in your read-only Library folder")
                                    }
                                }
                                Text(file.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            if isLocked {
                                Button("Delete", role: .destructive) {}
                                    .disabled(true)
                                    .help("Can't be deleted — it's in your read-only Library folder")
                            } else {
                                Button("Delete", role: .destructive) { Task { await viewModel.deleteDuplicate(file) } }
                            }
                        }
                    }
                }
            }
        }
    }

    private var suggestedRelationshipsSection: some View {
        Section("Suggested Relationships (\(viewModel.suggestedRelationships.count))") {
            // Bar comes first, not last — with a long queue the actions used to sit
            // below every row, so acting on a bulk selection meant scrolling all the
            // way down first.
            BulkActionBar(
                totalCount: viewModel.suggestedRelationships.count,
                selectedCount: checkedRelationshipIds.count,
                allSelected: !viewModel.suggestedRelationships.isEmpty && checkedRelationshipIds.count == viewModel.suggestedRelationships.count,
                onToggleSelectAll: { checkedRelationshipIds = $0 ? Set(viewModel.suggestedRelationships.compactMap(\.relationship.id)) : [] },
                onActionSelected: {
                    let ids = checkedRelationshipIds
                    Task {
                        await viewModel.confirmSelectedRelationships(ids: ids)
                        checkedRelationshipIds = []
                    }
                },
                onActionAll: { Task { await viewModel.confirmAllRelationships(); checkedRelationshipIds = [] } }
            )
            ForEach(viewModel.suggestedRelationships, id: \.relationship.id) { pair in
                HStack {
                    Toggle("", isOn: checkedBinding(pair.relationship.id, in: $checkedRelationshipIds))
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                    relationshipSuggestionText(pair).lineLimit(1)
                    Spacer()
                    ConfirmRejectButtons(
                        onConfirm: { Task { await viewModel.confirmRelationship(pair.relationship) } },
                        onReject: { Task { await viewModel.rejectRelationship(pair.relationship) } }
                    )
                }
            }
        }
    }

    private var suggestedProjectsSection: some View {
        Section("Suggested Projects (\(viewModel.suggestedProjectMemberships.count))") {
            BulkActionBar(
                totalCount: viewModel.suggestedProjectMemberships.count,
                selectedCount: checkedProjectMembershipKeys.count,
                allSelected: !viewModel.suggestedProjectMemberships.isEmpty && checkedProjectMembershipKeys.count == viewModel.suggestedProjectMemberships.count,
                onToggleSelectAll: { checkedProjectMembershipKeys = $0 ? Set(viewModel.suggestedProjectMemberships.map(\.id)) : [] },
                onActionSelected: {
                    let pairs = viewModel.suggestedProjectMemberships
                        .filter { checkedProjectMembershipKeys.contains($0.id) }
                        .map { (projectId: $0.membership.projectId, fileId: $0.membership.fileId) }
                    Task {
                        await viewModel.confirmSelectedProjectMemberships(pairs)
                        checkedProjectMembershipKeys = []
                    }
                },
                onActionAll: { Task { await viewModel.confirmAllProjectMemberships(); checkedProjectMembershipKeys = [] } }
            )
            ForEach(viewModel.suggestedProjectMemberships) { entry in
                HStack {
                    Toggle("", isOn: checkedBinding(entry.id, in: $checkedProjectMembershipKeys))
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                    projectSuggestionText(entry).lineLimit(1)
                    Spacer()
                    ConfirmRejectButtons(
                        onConfirm: { Task { await viewModel.confirmProjectMembership(entry.membership) } },
                        onReject: { Task { await viewModel.rejectProjectMembership(entry.membership) } }
                    )
                }
            }
        }
    }

    /// A uniformly-tinted row reads as one indistinct blob when scanning a long bulk
    /// queue — the two filenames (the thing you're actually deciding about) need to
    /// outrank the relationship type between them, not match it. Filenames stay
    /// `.primary`/emphasized; the connecting phrase is `.secondary` and untinted, so
    /// it recedes the way "and"/"→" would in running text.
    private func relationshipSuggestionText(_ pair: (relationship: Relationship, fromFile: SpoolFile, toFile: SpoolFile)) -> Text {
        Text(pair.fromFile.filename).fontWeight(.medium).foregroundColor(.primary)
        + Text(" \(pair.relationship.type.rawValue.replacingOccurrences(of: "_", with: " ")) ").foregroundColor(.secondary)
        + Text(pair.toFile.filename).fontWeight(.medium).foregroundColor(.primary)
    }

    private func projectSuggestionText(_ entry: SuggestedProjectMembershipEntry) -> Text {
        Text(entry.file.filename).fontWeight(.medium).foregroundColor(.primary)
        + Text(" → ").foregroundColor(.secondary)
        + Text(entry.project.name).fontWeight(.medium).foregroundColor(.primary)
    }

    private var pendingArchivesSection: some View {
        Section("Pending Archives (\(viewModel.pendingArchives.count))") {
            Text("Confirming extracts the archive into its folder and deletes the original — there's no undo. If you're not sure, reject it (you can always un-reject it below).")
                .font(.caption).foregroundStyle(.secondary)
            BulkActionBar(
                totalCount: viewModel.pendingArchives.count,
                selectedCount: checkedArchiveIds.count,
                allSelected: !viewModel.pendingArchives.isEmpty && checkedArchiveIds.count == viewModel.pendingArchives.count,
                onToggleSelectAll: { checkedArchiveIds = $0 ? Set(viewModel.pendingArchives.compactMap(\.id)) : [] },
                onActionSelected: {
                    let ids = checkedArchiveIds
                    Task {
                        await viewModel.confirmSelectedArchives(ids: ids)
                        checkedArchiveIds = []
                    }
                },
                onActionAll: { Task { await viewModel.confirmAllArchives(); checkedArchiveIds = [] } }
            )
            ForEach(viewModel.pendingArchives) { zip in
                HStack {
                    Toggle("", isOn: checkedBinding(zip.id, in: $checkedArchiveIds))
                        .labelsHidden()
                        .toggleStyle(.checkbox)
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
            // No native/pure-Swift .7z/.rar reader exists, and — confirmed live —
            // there's no way to run an external `unar`/`7z` from inside App Sandbox
            // either (file *read* access via a security-scoped bookmark doesn't extend
            // to *execute* rights). Rather than a dead-end "configure a tool" flow, this
            // just tells the user to extract it themselves; Spool picks up the
            // extracted files the normal way, and this row disappears on its own once
            // the original archive is deleted (`RescanService`'s missing-zip sweep).
            Text("Spool can't look inside .7z/.rar archives directly. Extract this one yourself — in Finder, or with whatever unarchiver you have — and Spool will pick up the extracted files automatically. Once you delete the original archive, it disappears from this list.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(viewModel.unsupportedArchives) { zip in
                HStack {
                    VStack(alignment: .leading) {
                        Text(zip.filename).lineLimit(1)
                        Text(zip.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button { OpenInAppService.revealInFinder(fileURL: URL(fileURLWithPath: zip.path)) } label: {
                        Image(systemName: "arrow.up.forward.app")
                    }
                    .buttonStyle(.plain)
                    .help("Reveal in Finder")
                    .accessibilityLabel("Reveal \(zip.filename) in Finder")
                }
            }
        }
    }

    private var rejectedArchivesSection: some View {
        Section("Rejected Archives (\(viewModel.rejectedArchives.count))") {
            BulkActionBar(
                totalCount: viewModel.rejectedArchives.count,
                selectedCount: checkedRejectedArchiveIds.count,
                allSelected: !viewModel.rejectedArchives.isEmpty && checkedRejectedArchiveIds.count == viewModel.rejectedArchives.count,
                actionLabel: "Un-reject",
                onToggleSelectAll: { checkedRejectedArchiveIds = $0 ? Set(viewModel.rejectedArchives.compactMap(\.id)) : [] },
                onActionSelected: {
                    let ids = checkedRejectedArchiveIds
                    Task {
                        await viewModel.unrejectSelectedArchives(ids: ids)
                        checkedRejectedArchiveIds = []
                    }
                },
                onActionAll: { Task { await viewModel.unrejectAllArchives(); checkedRejectedArchiveIds = [] } }
            )
            ForEach(viewModel.rejectedArchives) { zip in
                HStack {
                    Toggle("", isOn: checkedBinding(zip.id, in: $checkedRejectedArchiveIds))
                        .labelsHidden()
                        .toggleStyle(.checkbox)
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
    /// The verb this bar's two buttons perform — "Confirm" for every suggestion/
    /// archive queue, "Delete" for duplicates, "Un-reject"/"Check Again" for the
    /// archive sub-queues. Every queue gets the exact same Select All / "<verb>
    /// Selected (N)" / "<verb> All (N)" shape rather than each inventing its own.
    var actionLabel: String = "Confirm"
    /// Overrides just the "All" button's phrase (still followed by " (N)") when
    /// "<verb> All" alone would be read as "act on literally every row" rather than
    /// what it actually does — duplicates' "All" keeps one copy per group, so it
    /// says "Delete All Extra Copies" instead of the generic "Delete All". Every
    /// other queue's "All" really does mean every row, so they leave this nil.
    var allActionLabel: String? = nil
    var destructive: Bool = false
    let onToggleSelectAll: (Bool) -> Void
    let onActionSelected: () -> Void
    let onActionAll: () -> Void

    var body: some View {
        HStack {
            Toggle("Select All", isOn: Binding(get: { allSelected }, set: onToggleSelectAll))
                .toggleStyle(.checkbox)
            Spacer()
            Button("\(actionLabel) Selected (\(selectedCount))", role: destructive ? .destructive : nil, action: onActionSelected)
                .disabled(selectedCount == 0)
            // A fixed gap, not just HStack's default spacing — "<verb> Selected"'s
            // label width changes every time a checkbox is toggled, and without this
            // a click aimed at it right after a toggle can land on "<verb> All"
            // instead, silently acting on everything rather than the selection.
            Divider().frame(height: 12).padding(.horizontal, 4)
            Button("\(allActionLabel ?? "\(actionLabel) All") (\(totalCount))", role: destructive ? .destructive : nil, action: onActionAll)
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
