import UIKit

/// 把 inputAccessoryView 打死：键盘上方那条「上一个 / 下一个 / 完成」栏
/// （网页里那条 ^ v ✓）在原生里就是它，返回 nil 就不出现。
///
/// 注意：`inputAccessoryView` 在 UIResponder 上是可读写的 `var`，
/// 只重写 get 会报 "cannot override mutable property with read-only property"，
/// 所以 get/set 都要写，set 空实现。
final class RemoteTextField: UITextField {
    override var inputAccessoryView: UIView? {
        get { nil }
        set { }
    }
}
