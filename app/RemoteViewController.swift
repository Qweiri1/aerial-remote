import UIKit
import WebKit

/// 原生遥控器：整个界面还是那张网页（和手机 Safari 里看到的完全一样），
/// 但「输入框 + 键盘」换成原生的，原因有两条，都只有原生能解：
///   1. Safari 只允许在真实触摸的事件栈里 focus，电视上点输入框属于网络事件，
///      聚焦会被静默忽略 —— 所以网页版永远要先在手机上补点一下；
///      原生 becomeFirstResponder() 没有这个限制，可以跟电视同步弹。
///   2. 网页输入框在 iOS 上必然带一条「表单辅助栏」(^ v ✓)，网页层关不掉；
///      原生 UITextField 只要 inputAccessoryView 返回 nil 就彻底没有。
/// 输入条是浮在 webView 上的独立视图，键盘弹起时只抬高自己，webView 尺寸不动，
/// 所以下面的遥控器 UI 一个像素都不会被挤。
final class RemoteViewController: UIViewController, UITextFieldDelegate {

    private static let serverKey = "aerial.server"
    private static let defaultServer = "http://aerial.local:8899/"

    private var webView: WKWebView!
    private var bar: UIView!
    private var field: RemoteTextField!
    private var barBottom: NSLayoutConstraint!
    private var barVisible = false

    private var pollTimer: Timer?
    private var offStreak = 0
    private var lastSent: String?
    private var debounce: Timer?

    private var errorBox: UIStackView!
    private var errorLabel: UILabel!

    // MARK: - 触感
    // 网页里的 navigator.vibrate 在 WKWebView 里不存在（iOS 从来没实现过 Vibration API），
    // 所以页面把「该震了」这件事通过 messageHandlers.haptic 丢给这里，由原生真的震。
    private let hapticLight  = UIImpactFeedbackGenerator(style: .light)
    private let hapticMedium = UIImpactFeedbackGenerator(style: .medium)
    private let hapticHeavy  = UIImpactFeedbackGenerator(style: .heavy)
    private let hapticRigid  = UIImpactFeedbackGenerator(style: .rigid)
    private let hapticSoft   = UIImpactFeedbackGenerator(style: .soft)
    private let hapticNotify = UINotificationFeedbackGenerator()

    private var serverBase: String {
        var s = (UserDefaults.standard.string(forKey: Self.serverKey) ?? Self.defaultServer)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { s = Self.defaultServer }
        if !s.lowercased().hasPrefix("http") { s = "http://" + s }
        if !s.hasSuffix("/") { s += "/" }
        return s
    }

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupWebView()
        setupBar()
        setupErrorBox()
        prepareHaptics()

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(keyboardWillChange(_:)),
                       name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        nc.addObserver(self, selector: #selector(keyboardWillHide(_:)),
                       name: UIResponder.keyboardWillHideNotification, object: nil)

        load()
        startPolling()
    }

    deinit {
        pollTimer?.invalidate()
        // 消息处理器是被 userContentController 强引用的，不解绑会和自己形成循环
        webView?.configuration.userContentController
            .removeScriptMessageHandler(forName: "haptic")
        NotificationCenter.default.removeObserver(self)
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    // MARK: - 界面

    private func setupWebView() {
        let conf = WKWebViewConfiguration()
        conf.allowsInlineMediaPlayback = true
        conf.allowsPictureInPictureMediaPlayback = true
        conf.mediaTypesRequiringUserActionForPlayback = []

        // 网页 → 原生：haptic 通道
        let ucc = WKUserContentController()
        ucc.add(self, name: "haptic")
        conf.userContentController = ucc

        let wv = WKWebView(frame: .zero, configuration: conf)
        wv.backgroundColor = .black
        wv.isOpaque = false
        wv.navigationDelegate = self
        wv.allowsBackForwardNavigationGestures = false
        wv.scrollView.contentInsetAdjustmentBehavior = .never
        wv.scrollView.bounces = false
        wv.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(wv)
        NSLayoutConstraint.activate([
            wv.topAnchor.constraint(equalTo: view.topAnchor),
            wv.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            wv.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        webView = wv

        // 两指长按 1.2s：改服务器地址（不影响页面的单指操作）
        let lp = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        lp.numberOfTouchesRequired = 2
        lp.minimumPressDuration = 1.2
        lp.delegate = self
        wv.addGestureRecognizer(lp)
    }

    private func setupBar() {
        bar = UIView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.backgroundColor = UIColor(white: 0.15, alpha: 0.97)
        bar.layer.cornerRadius = 22
        bar.layer.cornerCurve = .continuous
        bar.layer.shadowColor = UIColor.black.cgColor
        bar.layer.shadowOpacity = 0.55
        bar.layer.shadowRadius = 20
        bar.layer.shadowOffset = CGSize(width: 0, height: 10)
        bar.alpha = 0
        bar.isHidden = true
        view.addSubview(bar)

        field = RemoteTextField()
        field.translatesAutoresizingMaskIntoConstraints = false
        field.backgroundColor = .clear
        field.textColor = .white
        field.tintColor = UIColor(red: 0.04, green: 0.52, blue: 1.0, alpha: 1.0)
        field.font = UIFont.systemFont(ofSize: 17)
        field.returnKeyType = .send
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.autocapitalizationType = .none
        field.clearButtonMode = .whileEditing
        field.delegate = self
        field.addTarget(self, action: #selector(textChanged), for: .editingChanged)
        bar.addSubview(field)

        barBottom = bar.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -80)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            bar.heightAnchor.constraint(equalToConstant: 48),
            barBottom,
            field.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 18),
            field.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -18),
            field.topAnchor.constraint(equalTo: bar.topAnchor),
            field.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
        ])
    }

    private func setupErrorBox() {
        errorLabel = UILabel()
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.textColor = UIColor(white: 0.75, alpha: 1)
        errorLabel.font = UIFont.systemFont(ofSize: 15)
        errorLabel.numberOfLines = 0
        errorLabel.textAlignment = .center

        let btn = UIButton(type: .system)
        btn.setTitle("更改服务器地址", for: .normal)
        btn.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        btn.addTarget(self, action: #selector(editServer), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [errorLabel, btn])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .center
        stack.isHidden = true
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
        ])
        errorBox = stack
    }

    // MARK: - 触感

    fileprivate func prepareHaptics() {
        hapticLight.prepare(); hapticMedium.prepare(); hapticHeavy.prepare()
        hapticRigid.prepare(); hapticSoft.prepare(); hapticNotify.prepare()
    }

    /// 网页里 haptic('light'|'medium'|'heavy'|'rigid'|'soft') 的落点
    fileprivate func fireHaptic(_ kind: String) {
        switch kind {
        case "heavy":   hapticHeavy.impactOccurred()
        case "medium":  hapticMedium.impactOccurred()
        case "rigid":   hapticRigid.impactOccurred()
        case "soft":    hapticSoft.impactOccurred()
        case "success": hapticNotify.notificationOccurred(.success)
        case "warning": hapticNotify.notificationOccurred(.warning)
        case "error":   hapticNotify.notificationOccurred(.error)
        default:        hapticLight.impactOccurred()
        }
        prepareHaptics()          // 震完立刻预热，下一次点下去才跟手
    }

    // MARK: - 加载

    private func load() {
        guard let url = URL(string: serverBase + "?native=1") else { return }
        errorBox.isHidden = true
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        webView.load(req)
    }

    // MARK: - 输入条

    private func showBar() {
        guard !barVisible else { return }
        barVisible = true
        lastSent = nil
        field.text = ""
        bar.isHidden = false
        view.bringSubviewToFront(bar)
        UIView.animate(withDuration: 0.16) { self.bar.alpha = 1 }
        // 原生不受「必须用户手势」限制，这一句就会把键盘顶出来
        field.becomeFirstResponder()
    }

    private func hideBar() {
        guard barVisible else { return }
        barVisible = false
        field.resignFirstResponder()
        UIView.animate(withDuration: 0.16, animations: { self.bar.alpha = 0 }) { _ in
            if !self.barVisible { self.bar.isHidden = true }
        }
    }

    @objc private func keyboardWillChange(_ note: Notification) {
        guard let info = note.userInfo,
              let value = info[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return }
        let frame = view.convert(value.cgRectValue, from: nil)
        let overlap = max(0, view.bounds.maxY - frame.minY)
        let duration = (info[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        applyBarPosition(overlap: overlap, duration: duration)
    }

    @objc private func keyboardWillHide(_ note: Notification) {
        let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        applyBarPosition(overlap: 0, duration: duration)
    }

    private func applyBarPosition(overlap: CGFloat, duration: Double) {
        let pad: CGFloat = overlap > 0 ? 10 : (view.safeAreaInsets.bottom + 12)
        barBottom.constant = -(overlap + pad)
        UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseOut]) {
            self.view.layoutIfNeeded()
        }
    }

    // MARK: - 和电视同步

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    private func poll() {
        guard let url = URL(string: serverBase + "api/ime") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 4
        req.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self = self, let data = data,
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let shown = obj["shown"] as? Bool else { return }
            DispatchQueue.main.async {
                if shown {
                    self.offStreak = 0
                    self.showBar()
                } else {
                    self.offStreak += 1
                    // 连续两次读不到焦点才收，挡住输入法切换时的瞬时抖动
                    if self.offStreak >= 2 { self.hideBar() }
                }
            }
        }.resume()
    }

    private func post(text: String, enter: Bool) {
        guard let url = URL(string: serverBase + "api/text") else { return }
        let payload: [String: Any] = ["text": text, "enter": enter, "replace": true]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        req.timeoutInterval = 5
        URLSession.shared.dataTask(with: req).resume()
    }

    @objc private func textChanged() {
        debounce?.invalidate()
        debounce = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            let v = self.field.text ?? ""
            if let last = self.lastSent, last == v { return }
            self.lastSent = v
            self.post(text: v, enter: false)   // 整段覆盖：电视上退格也跟着删
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        debounce?.invalidate()
        let v = textField.text ?? ""
        post(text: v, enter: true)
        textField.text = ""
        lastSent = ""
        return false
    }

    // MARK: - 服务器地址

    @objc private func handleLongPress(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        editServer()
    }

    @objc private func editServer() {
        let alert = UIAlertController(title: "服务器地址",
                                      message: "填电脑上遥控服务地址，例如 192.168.3.14:8899",
                                      preferredStyle: .alert)
        alert.addTextField { tf in
            tf.text = UserDefaults.standard.string(forKey: Self.serverKey) ?? Self.defaultServer
            tf.keyboardType = .URL
            tf.autocapitalizationType = .none
            tf.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "保存", style: .default) { _ in
            let v = alert.textFields?.first?.text ?? ""
            UserDefaults.standard.set(v, forKey: Self.serverKey)
            self.load()
            self.startPolling()
        })
        present(alert, animated: true)
    }
}

// MARK: - WKScriptMessageHandler

extension RemoteViewController: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "haptic" else { return }
        fireHaptic((message.body as? String) ?? "light")
    }
}

// MARK: - WKNavigationDelegate

extension RemoteViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        errorBox.isHidden = true
        prepareHaptics()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showError("连不上 \(serverBase)\n检查电视/电脑是否开着，手机和电脑是否同一 Wi-Fi。")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showError("页面加载失败：\(error.localizedDescription)")
    }

    private func showError(_ text: String) {
        errorLabel.text = text
        errorBox.isHidden = false
        view.bringSubviewToFront(errorBox)
    }
}

// MARK: - 手势并存

extension RemoteViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}
