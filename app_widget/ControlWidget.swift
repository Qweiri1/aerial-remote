import WidgetKit
import SwiftUI
import AppIntents

// ============================================================
//  桌面 2×2「一键开关机」小组件 + 控制中心「遥控器」
//
//  桌面小组件：
//    - systemSmall（2×2），纯黑底
//    - 上半部分是电源键：电视关着 → 开机并全屏；开着 → 关机
//    - 其余空白区域轻点 → widgetURL 拉起 App
//  控制中心：
//    - ControlWidgetButton + OpenRemoteIntent（openAppWhenRun）
//    - OpenRemoteIntent 定义在 shared/RemoteIntents.swift，主 App 和扩展各编一份；
//      系统拉起 App 后执行的是 App 侧那份 —— 只在扩展里的话点了没反应
// ============================================================

let powerKind = "tv.aerial.remote.power"

/// 扩展里的服务器地址：extension 和主 App 的 UserDefaults 不通（未配 App Group），
/// 读不到就用 aerial.local（mDNS 广播，和主 App 默认地址一致）。
let widgetServerBase: String = {
    var s = UserDefaults.standard.string(forKey: "aerial.server") ?? ""
    s = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.isEmpty { s = "http://aerial.local:8899/" }
    if !s.lowercased().hasPrefix("http") { s = "http://" + s }
    if !s.hasSuffix("/") { s += "/" }
    return s
}()

/// 和电脑上遥控服务的最小客户端
enum TVApi {
    static func isRunning() -> Bool {
        guard let url = URL(string: widgetServerBase + "api/ping") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 4
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let sem = DispatchSemaphore(value: 0)
        var running = false
        URLSession.shared.dataTask(with: req) { data, _, _ in
            if let d = data,
               let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
                running = (o["running"] as? Bool) ?? false
            }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 4.5)
        return running
    }

    /// 返回服务端的中文文案（「正在打开电视…」「正在关机…」等）
    static func tv(_ action: String) -> String {
        guard let url = URL(string: widgetServerBase + "api/tv") else { return "服务器地址不对" }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["action": action])
        req.timeoutInterval = 8
        let sem = DispatchSemaphore(value: 0)
        var msg = "没连上电视服务"
        URLSession.shared.dataTask(with: req) { data, _, _ in
            if let d = data,
               let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
               let m = o["msg"] as? String, !m.isEmpty {
                msg = m
            }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 8.5)
        return msg
    }
}

/// 开关机二合一：先问电脑电视是不是开着，再决定发 open（开机+全屏）还是 power（关机）
struct PowerToggleIntent: AppIntent {
    static var title: LocalizedStringResource = "开关电视"
    static var description: IntentDescription = IntentDescription(
        "电视关着就开机并全屏，开着就关机", categoryName: "Aerial TV")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let running = TVApi.isRunning()
        let msg = TVApi.tv(running ? "power" : "open")
        WidgetCenter.shared.reloadTimelines(ofKind: powerKind)   // 让电源图标状态尽快刷新
        return .result(dialog: IntentDialog(stringLiteral: msg))
    }
}

struct PowerEntry: TimelineEntry {
    let date: Date
    let running: Bool
}

struct PowerProvider: TimelineProvider {
    func placeholder(in context: Context) -> PowerEntry {
        PowerEntry(date: Date(), running: true)
    }
    func getSnapshot(in context: Context, completion: @escaping (PowerEntry) -> Void) {
        completion(PowerEntry(date: Date(), running: TVApi.isRunning()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<PowerEntry>) -> Void) {
        let entry = PowerEntry(date: Date(), running: TVApi.isRunning())
        // 两分钟对一次状态，不追求实时，够用且省系统预算
        completion(Timeline(entries: [entry],
                            policy: .after(Date().addingTimeInterval(120))))
    }
}

/// 2×2 黑底：上方电源键，其余空白处点进 App
struct PowerOnWidgetView: View {
    var entry: PowerEntry

    private var hint: String { entry.running ? "关机" : "开机全屏" }
    private var tint: Color {
        entry.running ? Color(red: 0.20, green: 0.92, blue: 0.55) : .white
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(intent: PowerToggleIntent()) {
                VStack(spacing: 5) {
                    Image(systemName: "power.circle.fill")
                        .font(.system(size: 40, weight: .regular))
                        .foregroundStyle(tint)
                    Text(hint)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
                .padding(.bottom, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Text("轻点空白处打开遥控器")
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.42))
                .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetURL(URL(string: "aerialremote://open"))     // 空白处点一下 = 打开 App
        .containerBackground(for: .widget) { Color.black }
    }
}

struct PowerOnWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: powerKind, provider: PowerProvider()) { entry in
            PowerOnWidgetView(entry: entry)
        }
        .configurationDisplayName("一键开关机")
        .description("点电源键开关电视，点空白处打开遥控器")
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
        PowerOnWidget()
        AerialRemoteControl()
    }
}
