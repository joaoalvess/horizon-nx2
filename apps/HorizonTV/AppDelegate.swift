import GameController
import SwiftUI
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = GameRootController(model: TVModel.shared)
        window.makeKeyAndVisible()
        self.window = window
        TVModel.shared.start()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        TVModel.shared.enteredBackground()
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        TVModel.shared.enteredForeground()
    }
}

final class GameRootController: GCEventViewController {
    private let model: TVModel

    init(model: TVModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        let hosting = UIHostingController(rootView: RootView().environment(model))
        addChild(hosting)
        hosting.view.frame = view.bounds
        hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(hosting.view)
        hosting.didMove(toParent: self)
        controllerUserInteractionEnabled = true
        model.onCapture = { [weak self] captures in self?.controllerUserInteractionEnabled = !captures }
    }
}
