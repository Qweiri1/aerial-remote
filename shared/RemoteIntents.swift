import AppIntents

// 这份文件同时编进主 App 和 widget 扩展 —— 关键就在这：
// openAppWhenRun 的意图必须主 App 里也有一份。文档写明：意图在扩展里跑时，
// 系统会拉起 App 并执行 App 侧的 perform —— App 里没有这个类型，点击就没反应。
// 之前 OpenRemoteIntent 只活在扩展里，这就是控制中心那颗按钮打不开 App 的病根。
@available(iOS 17, *)
struct OpenRemoteIntent: AppIntent {
    static var title: LocalizedStringResource = "打开遥控器"
    static var openAppWhenRun: Bool = true
    static var description: IntentDescription? = IntentDescription("打开 Aerial 遥控器")

    func perform() async throws -> some IntentResult {
        .result()
    }
}
