import BitwardenKit
import BitwardenKitMocks
import BitwardenResources
import BitwardenSdk
import TestHelpers
import Testing

@testable import BitwardenShared
@testable import BitwardenSharedMocks

/// Tests explicit website association before returning password credentials to iOS.
@MainActor
struct AutofillSaveWebsiteTests {
    private let appExtensionDelegate = MockAppExtensionDelegate()
    private let cipherMatchingHelper = MockCipherMatchingHelper()
    private let coordinator = MockCoordinator<VaultRoute, AuthAction>()
    private let stateService = MockStateService()
    private let vaultRepository = MockVaultRepository()

    private var subject: AutofillHelper {
        AutofillHelper(
            appExtensionDelegate: appExtensionDelegate,
            coordinator: coordinator.asAnyCoordinator(),
            services: ServiceContainer.withMocks(
                stateService: stateService,
                vaultRepository: vaultRepository,
            ),
            cipherMatchingHelper: cipherMatchingHelper,
        )
    }

    init() {
        appExtensionDelegate.uri = "https://example.com"
        stateService.activeAccount = .fixture()
        cipherMatchingHelper.doesCipherMatchReturnValue = .none
        vaultRepository.fetchCipherResult = .success(.fixture(
            login: .fixture(password: "password", username: "user"),
        ))
    }

    @Test
    func saveBeforeFilling() async throws {
        let helper = subject
        await helper.handleCipherForAutofill(
            cipherListView: .fixture(id: "1"),
            offerSaveForURI: "https://example.com",
        ) { _ in }

        #expect(appExtensionDelegate.didCompleteAutofillRequestUsername == nil)
        #expect(vaultRepository.updateCipherCiphers.isEmpty)
        let alert = try #require(coordinator.alertShown.last)
        try await alert.tapAction(title: Localizations.autofillAndSaveWebsite)

        #expect(vaultRepository.updateCipherCiphers.count == 1)
        #expect(vaultRepository.updateCipherCiphers.first?.login?.uris?.last?.uri == "https://example.com")
        #expect(appExtensionDelegate.didCompleteAutofillRequestUsername == "user")
        #expect(!coordinator.isLoadingOverlayShowing)
    }

    @Test(arguments: [true, false])
    func saveFailureRequiresExplicitFill(fillOnly: Bool) async throws {
        vaultRepository.updateCipherResult = .failure(BitwardenTestError.example)
        let helper = subject
        await helper.handleCipherForAutofill(
            cipherListView: .fixture(id: "1"),
            offerSaveForURI: "https://example.com",
        ) { _ in }
        let confirmation = try #require(coordinator.alertShown.last)
        try await confirmation.tapAction(title: Localizations.autofillAndSaveWebsite)

        #expect(appExtensionDelegate.didCompleteAutofillRequestUsername == nil)
        #expect(!coordinator.isLoadingOverlayShowing)
        let error = try #require(coordinator.alertShown.last)
        #expect(error.title == Localizations.autofillSaveWebsiteFailed("example.com"))
        try await error.tapAction(title: fillOnly ? Localizations.autofillOnly : Localizations.cancel)
        #expect(appExtensionDelegate.didCompleteAutofillRequestUsername == (fillOnly ? "user" : nil))
        #expect(vaultRepository.updateCipherCiphers.count == 1)
    }

    @Test(arguments: [true, false])
    func confirmationFillOnlyOrCancel(fillOnly: Bool) async throws {
        let helper = subject
        await helper.handleCipherForAutofill(
            cipherListView: .fixture(id: "1"),
            offerSaveForURI: "https://example.com",
        ) { _ in }
        let alert = try #require(coordinator.alertShown.last)
        try await alert.tapAction(title: fillOnly ? Localizations.autofillOnly : Localizations.cancel)
        #expect(appExtensionDelegate.didCompleteAutofillRequestUsername == (fillOnly ? "user" : nil))
        #expect(vaultRepository.updateCipherCiphers.isEmpty)
    }

    @Test
    func matchingLoginFillsImmediately() async {
        cipherMatchingHelper.doesCipherMatchReturnValue = .exact
        await subject.handleCipherForAutofill(
            cipherListView: .fixture(id: "1"),
            offerSaveForURI: "https://example.com",
        ) { _ in }
        #expect(coordinator.alertShown.isEmpty)
        #expect(vaultRepository.updateCipherCiphers.isEmpty)
        #expect(appExtensionDelegate.didCompleteAutofillRequestUsername == "user")
    }

    @Test
    func readOnlyLoginFillsWithoutSave() async {
        vaultRepository.fetchCipherResult = .success(.fixture(
            edit: false,
            login: .fixture(password: "password", username: "user"),
        ))
        await subject.handleCipherForAutofill(
            cipherListView: .fixture(id: "1"),
            offerSaveForURI: "https://example.com",
        ) { _ in }
        #expect(coordinator.alertShown.isEmpty)
        #expect(vaultRepository.updateCipherCiphers.isEmpty)
        #expect(appExtensionDelegate.didCompleteAutofillRequestUsername == "user")
    }

    @Test
    func duplicateURIIsNotAdded() async throws {
        vaultRepository.fetchCipherResult = .success(.fixture(
            login: .fixture(
                password: "password",
                uris: [.fixture(uri: "https://example.com")],
                username: "user",
            ),
        ))
        let helper = subject
        await helper.handleCipherForAutofill(
            cipherListView: .fixture(id: "1"),
            offerSaveForURI: "https://example.com",
        ) { _ in }
        let alert = try #require(coordinator.alertShown.last)
        try await alert.tapAction(title: Localizations.autofillAndSaveWebsite)
        #expect(vaultRepository.updateCipherCiphers.isEmpty)
        #expect(appExtensionDelegate.didCompleteAutofillRequestUsername == "user")
    }

    @Test
    func accountSwitchInvalidatesConfirmation() async throws {
        let helper = subject
        await helper.handleCipherForAutofill(
            cipherListView: .fixture(id: "1"),
            offerSaveForURI: "https://example.com",
        ) { _ in }
        let alert = try #require(coordinator.alertShown.last)
        stateService.activeAccount = nil
        try await alert.tapAction(title: Localizations.autofillAndSaveWebsite)
        #expect(vaultRepository.updateCipherCiphers.isEmpty)
        #expect(appExtensionDelegate.didCompleteAutofillRequestUsername == nil)
    }
}
