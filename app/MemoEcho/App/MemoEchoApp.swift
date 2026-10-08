import SwiftUI

@main
struct MemoEchoApp: App {
    @NSApplicationDelegateAdaptor(MemoEchoApplicationDelegate.self) private var appDelegate
    @State private var appCoordinator: AppCoordinator

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(appCoordinator: appCoordinator)
        } label: {
            Image("MenuBarIcon")
        }
        .menuBarExtraStyle(.menu)

        Window("关于 MemoEcho", id: "about") {
            AboutView(appCoordinator: appCoordinator)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }

    init() {
        let coordinator = AppCoordinator()
        _appCoordinator = State(initialValue: coordinator)
        appDelegate.windowPresence = coordinator.windowPresence

        // 首次启动检查放在 onAppear 等同位置不可靠，使用 DispatchQueue 保证时序
        // 单元测试宿主不得注册全局快捷键、发起真实配置验证或打开引导窗口。
        if NSClassFromString("XCTestCase") == nil {
            DispatchQueue.main.async {
                coordinator.handleAppLaunch()
            }
        }
    }
}
