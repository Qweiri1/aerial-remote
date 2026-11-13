import UIKit

// 显式入口，不依赖 @UIApplicationMain / @main，任何 Xcode 版本都不会被语言模式卡住。
_ = UIApplicationMain(
    CommandLine.argc,
    CommandLine.unsafeArgv,
    nil,
    NSStringFromClass(AppDelegate.self)
)
