import WidgetKit
import SwiftUI
import AppIntents

/// 控制中心「遥控器」+ 桌面 2×2「一键开机全屏」小组件。
/// iOS 18 起第三方 App 才能往控制中心放自己的控件（ControlWidget），
/// 点一下直接拉起 Aerial 遥控器 —— 不用先回桌面找图标。
/// OpenRemoteIntent 定义在 shared/RemoteIntents.swift（主 App 和扩展各编一份），
/// openAppWhenRun 才能真正把 App 拉起来。

/// 桌面小组件的意图：不打开 App，直接在后台叫服务器开机 + 全屏。
struct PowerOnIntent: AppIntent {
    static var title: LocalizedStringResource = "电视开机并全屏"
    static var description: IntentDescription = IntentDescription(
        "打开电视并自动全屏", categoryName: "Aerial TV")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let url = URL(string: widgetServerBase + "api/tv") else {
            return .result(dialog: "服务器地址不对")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["action": "open"])
        req.timeoutInterval = 12
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            // 复用服务端的中文文案：「电视已经在播了」「正在打开电视…」等
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let msg = obj["msg"] as? String, !msg.isEmpty {
                return .result(dialog: IntentDialog(stringLiteral: msg))
            }
            return .result(dialog: "已发出开机指令")
        } catch {
            return .result(dialog: "没连上电视服务")
        }
    }
}

struct PowerEntry: TimelineEntry { let date: Date }

struct PowerProvider: TimelineProvider {
    func placeholder(in context: Context) -> PowerEntry { PowerEntry(date: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (PowerEntry) -> Void) {
        completion(PowerEntry(date: Date()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<PowerEntry>) -> Void) {
        completion(Timeline(entries: [PowerEntry(date: Date())], policy: .never))
    }
}

/// 2×2（systemSmall）：整块都是按钮，点了就开机全屏，不需要打开 App。
struct PowerOnWidgetView: View {
    var entry: PowerEntry

    var body: some View {
        AppIntentButton(action: PowerOnIntent()) {
            VStack(spacing: 8) {
                Image(systemName: "tv.inset.filled.badge.play")
                    .font(.system(size: 38, weight: .semibold))
                Text("开机全屏")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .containerBackground(for: .widget) {
            LinearGradient(
                colors: [Color(red: 0.07, green: 0.33, blue: 0.68),
                         Color(red: 0.02, green: 0.12, blue: 0.32)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

struct PowerOnWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "tv.aerial.remote.power", provider: PowerProvider()) { entry in
            PowerOnWidgetView(entry: entry)
        }
        .configurationDisplayName("一键开机全屏")
        .description("点一下：电视开机并自动全屏，不打开 App")
        .supportedFamilies([.systemSmall])
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
        PowerOnWidget()
    }
}

/// 扩展进程里读服务器地址：extension 的 UserDefaults 和主 App 不通
/// （没配 App Group），所以这里读自己的 standard，读不到就用 aerial.local。
/// App 侧改过地址的话跟我说一声，我再加 App Group 共享。
let widgetServerBase: String = {
    var s = UserDefaults.standard.string(forKey: "aerial.server") ?? ""
    s = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.isEmpty { s = "http://aerial.local:8899/" }
    if !s.lowercased().hasPrefix("http") { s = "http://" + s }
    if !s.hasSuffix("/") { s += "/" }
    return s
}()
