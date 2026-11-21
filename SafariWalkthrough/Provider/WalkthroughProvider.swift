import AuthenticationServices
import BitwardenKit
import BitwardenKitMocks
import BitwardenResources
import BitwardenSdk
import Combine
import Foundation
import SwiftUI
import UIKit

@testable import BitwardenShared
@testable import BitwardenSharedMocks

// Fixture infrastructure is confined to this standalone simulator target.
// The actual picker, selection processor, AutofillHelper, alerts and iOS handoff are used.
enum WalkthroughAPI {
    static let base = URL(string: "http://127.0.0.1:8765")!

    static func call(_ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.timeoutInterval = 10
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "DisposableWalkthrough", code: 500)
        }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }
}

@MainActor
final class WalkthroughRepository: MockVaultRepository {
    override func updateCipher(_ cipher: BitwardenSdk.CipherView) async throws {
        // A loopback fixture store, not a real vault. It can reject the update deterministically.
        _ = try await WalkthroughAPI.call("save", body: [
            "uris": cipher.login?.uris?.compactMap(\.uri) ?? []
        ])
        fetchCipherResult = .success(cipher)
    }
}

@MainActor
final class WalkthroughDelegate: MockCredentialProviderExtensionDelegate {
    weak var provider: ASCredentialProviderViewController?

    override func completeAutofillRequest(username: String, password: String, fields: [(String, String)]?) {
        Task { @MainActor in
            do {
                _ = try await WalkthroughAPI.call("handoff", body: [:])
                provider?.extensionContext.completeRequest(
                    withSelectedCredential: ASPasswordCredential(user: username, password: password),
                    completionHandler: nil
                )
            } catch {
                provider?.extensionContext.cancelRequest(withError: error)
            }
        }
    }

    override func didCancel() {
        provider?.extensionContext.cancelRequest(withError: ASExtensionError(.userCanceled))
    }
}

@MainActor
final class WalkthroughCoordinator: Coordinator, HasStackNavigator {
    typealias Route = VaultRoute
    typealias Event = AuthAction
    weak var stackNavigator: StackNavigator?
    weak var delegate: WalkthroughDelegate?

    func start() {}
    func handleEvent(_ event: AuthAction, context: AnyObject?) async {}
    func navigate(to route: VaultRoute, context: AnyObject?) {}
    func showErrorAlert(error: Error, tryAgain: (() async -> Void)?, onDismissed: (() -> Void)?) async {
        showAlert(.defaultAlert(title: error.localizedDescription))
    }
}

// Suppress background sync/search publishers in this fixture picker. Selection and
// cancellation still run through the unmodified production processor.
@MainActor
final class WalkthroughPicker: StateProcessor<
    VaultAutofillListState, VaultAutofillListAction, VaultAutofillListEffect
> {
    let production: VaultAutofillListProcessor

    init(production: VaultAutofillListProcessor, state: VaultAutofillListState) {
        self.production = production
        super.init(state: state)
    }

    override func receive(_ action: VaultAutofillListAction) {
        if case .cancelTapped = action { production.receive(action) }
    }

    override func perform(_ effect: VaultAutofillListEffect) async {
        if case .vaultItemTapped = effect { await production.perform(effect) }
    }
}

@MainActor
final class WalkthroughProvider: ASCredentialProviderViewController {
    private var delegate: WalkthroughDelegate?
    private var coordinator: WalkthroughCoordinator?
    private var picker: WalkthroughPicker?
    private var navigation: UINavigationController?

    override func prepareInterfaceForExtensionConfiguration() {
        extensionContext.completeExtensionConfigurationRequest()
    }

    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        showFixture(serviceIdentifiers)
    }

    override func prepareCredentialList(
        for serviceIdentifiers: [ASCredentialServiceIdentifier],
        requestParameters: ASPasskeyCredentialRequestParameters
    ) {
        showFixture(serviceIdentifiers)
    }

    private func showFixture(_ identifiers: [ASCredentialServiceIdentifier]) {
        Task { await loadFixture(identifiers) }
    }

    private func loadFixture(_ identifiers: [ASCredentialServiceIdentifier]) async {
        do {
            let config = try await WalkthroughAPI.call("state")
            let identifier = identifiers.first?.identifier ?? "127.0.0.1"
            let uri = identifier.contains("://") ? identifier : "https://" + identifier
            let mode = config["mode"] as? String ?? "success"
            var uris = config["savedURIs"] as? [String] ?? []
            if mode == "matching" { uris = [uri] }
            let loginURIs = uris.map { LoginUriView(uri: $0, match: nil, uriChecksum: nil) }
            let repository = WalkthroughRepository()
            repository.fetchCipherResult = .success(.fixture(
                edit: mode != "readonly",
                login: .fixture(
                    password: "Disposable-Only-42!",
                    uris: loginURIs,
                    username: "safari-fixture@example.invalid"
                ),
                name: "Safari disposable login"
            ))
            let stateService = MockStateService()
            stateService.activeAccount = .fixture()
            let services = ServiceContainer.withMocks(
                stateService: stateService,
                vaultRepository: repository
            )
            let delegate = WalkthroughDelegate()
            delegate.provider = self
            delegate.uri = uri
            delegate.extensionMode = .autofillVaultList(identifiers)
            delegate.isInAppExtension = true
            let coordinator = WalkthroughCoordinator()
            let navigation = UINavigationController()
            coordinator.stackNavigator = navigation
            coordinator.delegate = delegate
            let cipher = CipherListView.fixture(
                name: "Safari disposable login",
                subtitle: "safari-fixture@example.invalid",
                type: .login(.fixture(uris: loginURIs)),
                edit: mode != "readonly"
            )
            guard let item = VaultListItem(cipherListView: cipher) else {
                throw NSError(domain: "DisposableWalkthrough", code: 1)
            }
            var state = VaultAutofillListState()
            state.loadingState = .data([VaultListSection(id: "fixture", items: [item], name: "Disposable vault")])
            state.showWebIcons = false
            let production = VaultAutofillListProcessor(
                appExtensionDelegate: delegate,
                coordinator: coordinator.asAnyCoordinator(),
                services: services,
                state: state
            )
            let picker = WalkthroughPicker(production: production, state: state)
            let content = VaultAutofillListView(
                store: Store(processor: picker),
                timeProvider: services.timeProvider
            )
            let hosting = UIHostingController(rootView: content)
            navigation.setViewControllers([hosting], animated: false)
            addChild(navigation)
            self.view.addSubview(navigation.view)
            navigation.view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                navigation.view.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
                navigation.view.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
                navigation.view.topAnchor.constraint(equalTo: self.view.topAnchor),
                navigation.view.bottomAnchor.constraint(equalTo: self.view.bottomAnchor)
            ])
            navigation.didMove(toParent: self)
            self.delegate = delegate
            self.coordinator = coordinator
            self.picker = picker
            self.navigation = navigation
        } catch {
            let alert = UIAlertController(title: "Fixture setup failed", message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
                self.extensionContext.cancelRequest(withError: error)
            })
            present(alert, animated: true)
        }
    }
}
