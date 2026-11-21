# Disposable Safari simulator walkthrough

This is a separate, explicitly generated test project. It is not embedded in the production Bitwarden app.

Generate `project-safari-walkthrough.yml` after the normal bootstrap, then build/test the `SafariWalkthrough` scheme on an iOS 18+ simulator. The fork's **Safari Autofill Walkthrough** workflow uses the standard `xcode-27` runner and the repository's pinned Xcode/device/runtime versions.

## What is real

Safari loads a local HTML login page. iOS enables and presents a real credential-provider extension. The extension displays the production `VaultAutofillListView`, forwards item selection to the production `VaultAutofillListProcessor`, and uses the unchanged `AutofillHelper` and UIKit alert presentation. The delegate completes the actual `ASCredentialProviderExtensionContext` request with disposable credentials. The page independently checks the resulting form values.

## What is a fixture

The containing app only enables the test provider and opens Safari. The repository and account services are test doubles; sync/search publishers are suppressed by a small picker adapter. A loopback-only Python server is the disposable URI store and deliberate save-failure injector. No Bitwarden account, Apple account, personal vault, or secret is used. Passwords are fixed, public test strings with no value outside this test.

The provider depends on existing test helpers and is only intended for Debug simulator execution. It must never be included in a shipping app. Its transport exception applies only to these test targets and their loopback fixture server.

## Assertions and evidence

The cases check:
- Saving succeeds before the extension hands credentials back, existing URIs are preserved, and the next selection matches without another save prompt.
- Autofill Only returns the disposable credentials without saving.
- Cancel leaves the form and disposable URI store untouched.
- A failed save leaves the picker/error visible without a credential handoff; Autofill Only is required to fill after failure.
- Cancelling after a failed save still leaves Safari untouched.
- Read-only items use the existing fill flow without offering a save.

Each case keeps screenshots and accessibility trees in the xcresult bundle. The server records event types and URI values, never the password. The workflow exports attachments, logs, the final simulator screenshot and the XCTest result summary to `safari-walkthrough-evidence`.

A passing run validates the Safari/extension UI boundary with a fixture vault. It does **not** validate production sign-in, encryption, remote vault persistence, synchronization, VoiceOver, or physical-device behavior. Those require separate validation.
