import SwiftUI
import UniformTypeIdentifiers

enum MerchantSortKey {
    case identifier, activeExpiration, readyToActivate
}

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
    var merchantCertificateStatuses: [MerchantCertificateStatus] = []
    var selectedMerchants: Set<String> = []
    var merchantSortKey: MerchantSortKey = .activeExpiration
    var merchantSortAscending: Bool = true
    var showActivateConfirmation = false

    var statusMessage: String?
    var progress: Double?
    var errorMessage: String?

    var isLoading: Bool { progress != nil }
    var canFetch: Bool { !apiKeyID.isEmpty && !apiKey.isEmpty && !issuerID.isEmpty && !isLoading }
    var canFetchMerchantCertificates: Bool { canFetch }
    var canAddTesters: Bool { !selectedApps.isEmpty && !selectedUsers.isEmpty && selectedBetaGroup != nil && !isLoading }

    var sortedMerchantCertificateStatuses: [MerchantCertificateStatus] {
        merchantCertificateStatuses.sorted { a, b in
            let result: Bool
            switch merchantSortKey {
            case .identifier:
                result = a.identifier.localizedCaseInsensitiveCompare(b.identifier) == .orderedAscending
            case .activeExpiration:
                result = (a.activeExpirationDate ?? .distantFuture) < (b.activeExpirationDate ?? .distantFuture)
            case .readyToActivate:
                result = a.hasReadyCertificateToActivate && !b.hasReadyCertificateToActivate
            }
            return merchantSortAscending ? result : !result
        }
    }

    var merchantsToActivate: [MerchantCertificateStatus] {
        merchantCertificateStatuses.filter { selectedMerchants.contains($0.id) && $0.hasReadyCertificateToActivate }
    }

    private var client: AppStoreConnectClient {
        AppStoreConnectClient(apiKeyID: apiKeyID, apiKey: apiKey, issuerID: issuerID)
    }

    private static let iso8601WithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    var hasValidP8Key: Bool {
        apiKey.contains("-----BEGIN PRIVATE KEY-----") && apiKey.contains("-----END PRIVATE KEY-----")
    }

    private func parseAPIDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        return Self.iso8601WithFractionalSeconds.date(from: value) ?? Self.iso8601.date(from: value)
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

    func fetchMerchantCertificateStatuses() async {
        errorMessage = nil
        progress = 0
        statusMessage = "Fetching merchant IDs…"

        do {
            let merchants = try await client.fetchAllMerchantIDs()
            var statuses: [MerchantCertificateStatus] = []
            let now = Date()

            if merchants.isEmpty {
                merchantCertificateStatuses = []
                progress = nil
                statusMessage = nil
                return
            }

            for (index, merchant) in merchants.enumerated() {
                statusMessage = "Fetching certificates for \(merchant.attributes.identifier)…"

                do {
                    let certificates = try await client.fetchMerchantCertificates(for: merchant.id)

                    let nonExpired = certificates.filter {
                        guard let dateStr = $0.attributes.expirationDate,
                              let date = parseAPIDate(dateStr) else { return false }
                        return date > now
                    }

                    let activeCert = nonExpired.first { $0.attributes.activated == true }
                    let activeExpirationDate = activeCert.flatMap { parseAPIDate($0.attributes.expirationDate) }

                    let pendingCert = nonExpired.first { $0.attributes.activated == false }
                    let pendingExpirationDate = pendingCert.flatMap { parseAPIDate($0.attributes.expirationDate) }

                    statuses.append(
                        MerchantCertificateStatus(
                            id: merchant.id,
                            identifier: merchant.attributes.identifier,
                            name: merchant.attributes.name,
                            activeExpirationDate: activeExpirationDate,
                            hasReadyCertificateToActivate: pendingCert != nil,
                            certificateIdToActivate: pendingCert?.id,
                            pendingExpirationDate: pendingExpirationDate
                        )
                    )
                } catch {
                    errorMessage = "Failed to fetch certificates for \(merchant.attributes.identifier): \(error.localizedDescription)"
                    statuses.append(
                        MerchantCertificateStatus(
                            id: merchant.id,
                            identifier: merchant.attributes.identifier,
                            name: merchant.attributes.name,
                            activeExpirationDate: nil,
                            hasReadyCertificateToActivate: false,
                            certificateIdToActivate: nil,
                            pendingExpirationDate: nil
                        )
                    )
                }

                progress = Double(index + 1) / Double(merchants.count)
            }

            merchantCertificateStatuses = statuses.sorted {
                ($0.activeExpirationDate ?? .distantFuture) < ($1.activeExpirationDate ?? .distantFuture)
            }
        } catch {
            merchantCertificateStatuses = []
            errorMessage = "Failed to fetch merchant IDs: \(error.localizedDescription)"
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

    func activateSelectedCertificates() async {
        let toActivate = merchantsToActivate
        guard !toActivate.isEmpty else { return }

        errorMessage = nil
        progress = 0
        let total = Double(toActivate.count)

        for (index, merchant) in toActivate.enumerated() {
            guard let certId = merchant.certificateIdToActivate else { continue }
            statusMessage = "Activating certificate for \(merchant.identifier)…"
            do {
                try await client.activateCertificate(id: certId)
            } catch {
                errorMessage = "Failed to activate certificate for \(merchant.identifier): \(error.localizedDescription)"
            }
            progress = Double(index + 1) / total
        }

        selectedMerchants.removeAll()
        progress = nil
        statusMessage = "Re-fetching merchant certificates…"
        await fetchMerchantCertificateStatuses()
    }
}

// MARK: - ContentView

struct ContentView: View {
    @State private var viewModel = AppViewModel()
    @State private var isDroppingP8 = false
    @State private var isEditingCredentials = false
    private static let merchantExpirationDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    var body: some View {
        VStack {
            credentialsSection
            tabsSection
            errorBanner
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

    // MARK: - Tabs

    private var tabsSection: some View {
        TabView {
            testFlightTab
                .tabItem { Label("TestFlight", systemImage: "airplane") }
            merchantCertificatesTab
                .tabItem { Label("Apple Pay", systemImage: "creditcard") }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var testFlightTab: some View {
        VStack {
            fetchButton
            listsSection
            betaGroupPicker
            addButton
        }
    }

    private func merchantSortIndicator(for key: MerchantSortKey) -> String {
        guard viewModel.merchantSortKey == key else { return "" }
        return viewModel.merchantSortAscending ? " ▲" : " ▼"
    }

    private func toggleMerchantSort(_ key: MerchantSortKey) {
        if viewModel.merchantSortKey == key {
            viewModel.merchantSortAscending.toggle()
        } else {
            viewModel.merchantSortKey = key
            viewModel.merchantSortAscending = true
        }
    }

    private var merchantCertificatesTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("Fetch Merchant IDs") {
                    Task { await viewModel.fetchMerchantCertificateStatuses() }
                }
                .disabled(!viewModel.canFetchMerchantCertificates)

                Spacer()

                if !viewModel.selectedMerchants.isEmpty {
                    Text("\(viewModel.selectedMerchants.count) selected")
                        .foregroundStyle(.secondary)
                }

                Text("\(viewModel.merchantCertificateStatuses.count) merchants")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)

            HStack {
                Button { toggleMerchantSort(.identifier) } label: {
                    Text("Merchant ID\(merchantSortIndicator(for: .identifier))")
                }
                .buttonStyle(.plain)
                Spacer()
                Button { toggleMerchantSort(.activeExpiration) } label: {
                    Text("Active cert expires\(merchantSortIndicator(for: .activeExpiration))")
                }
                .buttonStyle(.plain)
                .frame(width: 170, alignment: .leading)
                Button { toggleMerchantSort(.readyToActivate) } label: {
                    Text("Ready to activate\(merchantSortIndicator(for: .readyToActivate))")
                }
                .buttonStyle(.plain)
                .frame(width: 140, alignment: .leading)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal)

            List(viewModel.sortedMerchantCertificateStatuses) { merchant in
                HStack {
                    Toggle(isOn: Binding(
                        get: { viewModel.selectedMerchants.contains(merchant.id) },
                        set: { isOn in
                            if isOn { viewModel.selectedMerchants.insert(merchant.id) }
                            else { viewModel.selectedMerchants.remove(merchant.id) }
                        }
                    )) {
                        VStack(alignment: .leading) {
                            Text(merchant.identifier)
                            Text(merchant.name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                    Spacer()
                    Text(formattedMerchantExpirationDate(merchant.activeExpirationDate))
                        .foregroundStyle(merchantExpiresWithinOneMonth(merchant.activeExpirationDate) ? .yellow : .primary)
                        .frame(width: 170, alignment: .leading)
                    Label(
                        merchant.hasReadyCertificateToActivate ? "Yes" : "No",
                        systemImage: merchant.hasReadyCertificateToActivate ? "checkmark.circle.fill" : "xmark.circle"
                    )
                    .foregroundStyle(merchant.hasReadyCertificateToActivate ? .green : .secondary)
                    .frame(width: 140, alignment: .leading)
                }
            }

            HStack {
                Spacer()
                Button("Activate Certificates") {
                    viewModel.showActivateConfirmation = true
                }
                .disabled(viewModel.merchantsToActivate.isEmpty || viewModel.isLoading)
            }
            .padding(.horizontal)
            .confirmationDialog(
                "Activate Certificates",
                isPresented: $viewModel.showActivateConfirmation
            ) {
                Button("Activate \(viewModel.merchantsToActivate.count) Certificate(s)", role: .destructive) {
                    Task { await viewModel.activateSelectedCertificates() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(activateConfirmationMessage)
            }
        }
    }

    private var activateConfirmationMessage: String {
        let merchants = viewModel.merchantsToActivate
        var lines = ["Activate certificate for:\n"]
        for m in merchants {
            let expiry = m.pendingExpirationDate.map { Self.merchantExpirationDateFormatter.string(from: $0) } ?? "unknown"
            lines.append("• \(m.identifier) (expires \(expiry))")
        }
        lines.append("\nThis will make these certificates the active payment processing certificates.")
        return lines.joined(separator: "\n")
    }

    private func formattedMerchantExpirationDate(_ date: Date?) -> String {
        guard let date else { return "No active certificate" }
        return Self.merchantExpirationDateFormatter.string(from: date)
    }

    private func merchantExpiresWithinOneMonth(_ date: Date?) -> Bool {
        guard let date else { return false }
        guard let oneMonthFromNow = Calendar.current.date(byAdding: .month, value: 1, to: Date()) else { return false }
        return date < oneMonthFromNow
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
