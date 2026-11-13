import WidgetKit
import SwiftUI
import AppIntents

/// 控制中心里的那颗「遥控器」。
/// iOS 18 起第三方 App 才能往控制中心放自己的控件（ControlWidget），
/// 点一下直接拉起 Aerial 遥控器 —— 不用先回桌面找图标。
/// 这个文件属于 widget 扩展，扩展的 deployment target 就是 18.0，
/// 所以整份代码不用再套 @available。

/// 只做一件事：把 App 打开（openAppWhenRun）。perform 里不需要写逻辑。
struct OpenRemoteIntent: AppIntent {
    static var title: LocalizedStringResource = "打开遥控器"
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        .result()
    }
}

struct AerialRemoteControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "tv.aerial.remote.open") {
            ControlWidgetButton(action: OpenRemoteIntent()) {
                Label("遥控器", systemImage: "appletvremote.gen1")
            }
        }
        .displayName("Aerial 遥控器")
        .description("打开 Aerial 遥控器")
    }
}

@main
struct AerialRemoteWidgets: WidgetBundle {
    var body: some Widget {
        AerialRemoteControl()
    }
}
