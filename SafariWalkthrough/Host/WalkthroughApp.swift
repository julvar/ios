import AuthenticationServices
import UIKit

// This app and its extension are generated only by project-safari-walkthrough.yml.
@main
final class WalkthroughApp: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let controller = UIViewController()
        controller.view.backgroundColor = .systemBackground
        let label = UILabel()
        label.text = "Disposable Safari walkthrough"
        label.numberOfLines = 0
        let enable = UIButton(type: .system)
        enable.setTitle("Enable test provider", for: .normal)
        enable.accessibilityIdentifier = "enable-provider"
        enable.addAction(UIAction { _ in
            Task { @MainActor in
                let enabled = await ASSettingsHelper.requestToTurnOnCredentialProviderExtension()
                label.text = enabled ? "Test provider enabled" : "Test provider not enabled"
            }
        }, for: .touchUpInside)
        let safari = UIButton(type: .system)
        safari.setTitle("Open Safari test page", for: .normal)
        safari.accessibilityIdentifier = "open-safari"
        safari.addAction(UIAction { _ in
            UIApplication.shared.open(URL(string: "http://127.0.0.1:8765/login?run=" + UUID().uuidString)!)
        }, for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [label, enable, safari])
        stack.axis = .vertical
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: controller.view.centerYAnchor)
        ])
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}
