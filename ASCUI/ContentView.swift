import SwiftUI
import UniformTypeIdentifiers

@MainActor @Observable
final class AppViewModel {
    var apiKeyID: String = UserDefaults.standard.string(forKey: "apiKeyID") ?? ""
    var apiKey: String = Keychain.load(key: "apiKey") ?? ""
    var issuerID: String = UserDefaults.standard.string(forKey: "issuerID") ?? ""

    var apps: [ASCApp] = []
    var selectedApps: Set<ASCApp> = []

    var users: [User] = []
    var selectedUsers: Set<User> = []

    var betaGroups: [BetaGroup] = []
    var selectedBetaGroup: BetaGroup?

    var statusMessage: String?
    var progress: Double?
    var errorMessage: String?

    var isLoading: Bool { progress != nil }
    var canFetch: Bool { !apiKeyID.isEmpty && !apiKey.isEmpty && !issuerID.isEmpty && !isLoading }
    var canAddTesters: Bool { !selectedApps.isEmpty && !selectedUsers.isEmpty && selectedBetaGroup != nil && !isLoading }

    private var client: AppStoreConnectClient {
        AppStoreConnectClient(apiKeyID: apiKeyID, apiKey: apiKey, issuerID: issuerID)
    }

    var hasValidP8Key: Bool {
        apiKey.contains("-----BEGIN PRIVATE KEY-----") && apiKey.contains("-----END PRIVATE KEY-----")
    }

    func saveCredentials() {
        UserDefaults.standard.set(apiKeyID, forKey: "apiKeyID")
        UserDefaults.standard.set(issuerID, forKey: "issuerID")
        if apiKey.isEmpty {
            Keychain.delete(key: "apiKey")
        } else {
            Keychain.save(key: "apiKey", value: apiKey)
        }
    }

    func loadP8File(from url: URL) throws {
        let contents = try String(contentsOf: url, encoding: .utf8)
        apiKey = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        saveCredentials()
    }

    func fetchData() async {
        errorMessage = nil
        progress = 0
        statusMessage = "Fetching apps…"

        var appsOK = false
        do {
            apps = try await client.fetchApps()
            appsOK = true
        } catch {
            errorMessage = "Failed to fetch apps: \(error.localizedDescription)"
        }

        progress = 0.5
        statusMessage = appsOK ? "Fetched \(apps.count) apps. Fetching users…" : "Fetching users…"

        do {
            users = try await client.fetchAllUsers()
        } catch {
            errorMessage = "Failed to fetch users: \(error.localizedDescription)"
        }

        progress = nil
        statusMessage = nil
    }

    func fetchBetaGroups() async {
        guard !selectedApps.isEmpty else {
            betaGroups = []
            selectedBetaGroup = nil
            return
        }

        errorMessage = nil
        progress = 0
        statusMessage = "Fetching beta groups…"

        var allGroups: [BetaGroup] = []
        let appsArray = Array(selectedApps)

        for (i, app) in appsArray.enumerated() {
            statusMessage = "Fetching beta groups for \(app.attributes.name)…"
            do {
                let groups = try await client.fetchBetaGroups(for: app)
                if i == 0 {
                    allGroups = groups
                } else {
                    // Keep only groups that exist across all selected apps (by name)
                    let groupNames = Set(groups.map(\.attributes.name))
                    allGroups = allGroups.filter { groupNames.contains($0.attributes.name) }
                }
            } catch {
                errorMessage = "Failed to fetch beta groups for \(app.attributes.name): \(error.localizedDescription)"
            }
            progress = Double(i + 1) / Double(appsArray.count)
        }

        betaGroups = allGroups.sorted { $0.attributes.name < $1.attributes.name }
        if selectedBetaGroup == nil || !betaGroups.contains(where: { $0.id == selectedBetaGroup?.id }) {
            selectedBetaGroup = betaGroups.first
        }

        progress = nil
        statusMessage = nil
    }

    func addToTestFlight() async {
        guard let targetGroup = selectedBetaGroup else { return }
        errorMessage = nil

        let appsArray = Array(selectedApps)
        let usersArray = Array(selectedUsers)
        let totalSteps = Double(appsArray.count * usersArray.count)
        var completedSteps = 0.0

        progress = 0
        statusMessage = "Starting…"

        for app in appsArray {
            // Find the matching beta group for this app by name
            statusMessage = "Fetching beta groups for \(app.attributes.name)…"
            do {
                let groups = try await client.fetchBetaGroups(for: app)
                guard let betaGroup = groups.first(where: { $0.attributes.name == targetGroup.attributes.name }) else {
                    errorMessage = "Beta group '\(targetGroup.attributes.name)' not found for \(app.attributes.name)"
                    completedSteps += Double(usersArray.count)
                    progress = completedSteps / totalSteps
                    continue
                }

                for (i, user) in usersArray.enumerated() {
                    let name = [user.attributes.firstName, user.attributes.lastName]
                        .compactMap { $0 }.joined(separator: " ")
                    statusMessage = "Adding \(name) to \(app.attributes.name) (\(i + 1)/\(usersArray.count))…"

                    do {
                        try await client.addTester(email: user.attributes.username, toBetaGroup: betaGroup.id)
                    } catch {
                        errorMessage = "Failed to add \(name) to \(app.attributes.name): \(error.localizedDescription)"
                    }
                    completedSteps += 1
                    progress = completedSteps / totalSteps
                }
            } catch {
                errorMessage = "Failed to fetch beta groups for \(app.attributes.name): \(error.localizedDescription)"
                completedSteps += Double(usersArray.count)
                progress = completedSteps / totalSteps
            }
        }

        progress = nil
        statusMessage = nil
    }
}

// MARK: - ContentView

struct ContentView: View {
    @State private var viewModel = AppViewModel()
    @State private var isDroppingP8 = false
    @State private var isEditingCredentials = false

    var body: some View {
        VStack {
            credentialsSection
            fetchButton
            errorBanner
            listsSection
            betaGroupPicker
            addButton
            loadingIndicator
        }
        .padding()
        .onChange(of: viewModel.selectedApps) {
            Task { await viewModel.fetchBetaGroups() }
        }
    }

    // MARK: - Credentials

    private var credentialsAreSet: Bool {
        !viewModel.apiKeyID.isEmpty && !viewModel.issuerID.isEmpty && viewModel.hasValidP8Key
    }

    private var credentialsSection: some View {
        HStack {
            if credentialsAreSet && !isEditingCredentials {
                lockedCredentials
            } else {
                editableCredentials
            }
        }
        .padding()
    }

    private var lockedCredentials: some View {
        HStack {
            Label(viewModel.apiKeyID, systemImage: "key.fill")
                .foregroundStyle(.secondary)
            Spacer()
            Text("Issuer: \(viewModel.issuerID)")
                .foregroundStyle(.secondary)
            Spacer()
            Label("Key loaded", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Button {
                isEditingCredentials = true
            } label: {
                Image(systemName: "pencil.circle")
            }
            .buttonStyle(.plain)
        }
    }

    private var editableCredentials: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("API Key ID")
                TextField("Enter API Key ID", text: $viewModel.apiKeyID)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: viewModel.apiKeyID) { viewModel.saveCredentials() }
            }

            VStack(alignment: .leading) {
                Text("API Key")
                if viewModel.hasValidP8Key {
                    apiKeyDropZone
                } else {
                    TextField("Paste key or drop .p8", text: $viewModel.apiKey)
                        .textFieldStyle(.roundedBorder)
                        .onDrop(of: [.fileURL], isTargeted: $isDroppingP8) { providers in
                            handleP8Drop(providers)
                        }
                }
            }

            VStack(alignment: .leading) {
                Text("Issuer ID")
                TextField("Enter Issuer ID", text: $viewModel.issuerID)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: viewModel.issuerID) { viewModel.saveCredentials() }
            }

            if credentialsAreSet {
                Button {
                    isEditingCredentials = false
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                }
                .buttonStyle(.plain)
                .padding(.top, 16)
            }
        }
    }

    private var apiKeyDropZone: some View {
        HStack {
            Label("Key loaded", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Spacer()
            Button(role: .destructive) {
                viewModel.apiKey = ""
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 6)
        .frame(height: 22)
    }

    private func handleP8Drop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
            guard let data = data as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil),
                  url.pathExtension == "p8" else { return }
            Task { @MainActor in
                do {
                    try viewModel.loadP8File(from: url)
                } catch {
                    viewModel.errorMessage = "Failed to read .p8 file: \(error.localizedDescription)"
                }
            }
        }
        return true
    }

    // MARK: - Fetch

    private var fetchButton: some View {
        Button("Fetch Apps and Users") {
            Task { await viewModel.fetchData() }
        }
        .padding()
        .disabled(!viewModel.canFetch)
    }

    // MARK: - Error / Loading

    @ViewBuilder
    private var errorBanner: some View {
        if let errorMessage = viewModel.errorMessage {
            Text(errorMessage)
                .foregroundStyle(.red)
                .padding()
        }
    }

    @ViewBuilder
    private var loadingIndicator: some View {
        if let progress = viewModel.progress {
            VStack(spacing: 4) {
                ProgressView(value: progress)
                if let status = viewModel.statusMessage {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
        }
    }

    // MARK: - Lists

    private var listsSection: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("Apps (\(viewModel.selectedApps.count)/\(viewModel.apps.count))").font(.headline)
                List {
                    ForEach(viewModel.apps) { app in
                        Toggle(app.attributes.name, isOn: Binding(
                            get: { viewModel.selectedApps.contains(app) },
                            set: { isOn in
                                if isOn { viewModel.selectedApps.insert(app) }
                                else { viewModel.selectedApps.remove(app) }
                            }
                        ))
                        .toggleStyle(.checkbox)
                    }
                }
            }

            VStack(alignment: .leading) {
                Text("Users (\(viewModel.selectedUsers.count)/\(viewModel.users.count))").font(.headline)
                List {
                    ForEach(viewModel.users) { user in
                        Toggle(
                            "\(user.attributes.firstName ?? "") \(user.attributes.lastName ?? "")",
                            isOn: Binding(
                                get: { viewModel.selectedUsers.contains(user) },
                                set: { isOn in
                                    if isOn { viewModel.selectedUsers.insert(user) }
                                    else { viewModel.selectedUsers.remove(user) }
                                }
                            )
                        )
                        .toggleStyle(.checkbox)
                    }
                }
            }
        }
    }

    // MARK: - Beta Group Picker & Add

    private var betaGroupPicker: some View {
        HStack {
            Text("Beta Group:")
            if viewModel.betaGroups.isEmpty {
                Text("Select apps to load beta groups")
                    .foregroundStyle(.secondary)
            } else {
                Picker("", selection: $viewModel.selectedBetaGroup) {
                    ForEach(viewModel.betaGroups) { group in
                        Text(group.attributes.name).tag(Optional(group))
                    }
                }
                .labelsHidden()
            }
        }
        .padding(.horizontal)
    }

    private var addButton: some View {
        Button("Add to TestFlight") {
            Task { await viewModel.addToTestFlight() }
        }
        .padding()
        .disabled(!viewModel.canAddTesters)
    }
}
