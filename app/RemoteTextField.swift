import UIKit

/// 把 inputAccessoryView 打死：iOS 给输入框配的那条「上一个 / 下一个 / 完成」栏
/// （网页里那条 ^ v ✓）在原生里就是它，返回 nil 就彻底不出现。
final class RemoteTextField: UITextField {
    override var inputAccessoryView: UIView? { nil }
}
