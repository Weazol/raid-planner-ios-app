import UIKit
import WebKit
import Capacitor

/// Colors of the web app (styles.scss, --rp-* tokens).
enum AppTheme {
    /// --rp-bg, also the header color of the web app
    static let background = UIColor(red: 0x06 / 255.0, green: 0x19 / 255.0, blue: 0x33 / 255.0, alpha: 1)
    /// --rp-muted
    static let muted = UIColor(red: 0x9f / 255.0, green: 0xb6 / 255.0, blue: 0xc8 / 255.0, alpha: 1)
}

/// Root of the window. Keeps the web view inside the safe area, so the web app's header never
/// slides under the notch / Dynamic Island and its bottom stays clear of the home indicator,
/// without any change to the web app. The strips around it get the header color.
///
/// Capacitor reads the server address once, when its bridge is created. So whenever the addresses
/// change (setup page, iOS Settings app), a new bridge view controller replaces the old one.
final class RootViewController: UIViewController {
    private var bridgeViewController: AppBridgeViewController?
    private var shownSettings: AppSettings?

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    private let debugButton = DebugButton()
    private var loggedBridgeFrame: CGRect?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AppTheme.background
        let info = Bundle.main.infoDictionary
        DebugLog.add("app start, version \(info?["CFBundleShortVersionString"] ?? "?") build \(info?["CFBundleVersion"] ?? "?"), "
            + "\(UIDevice.current.model) \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
        showBridge()

        // TEMPORARY: debug log button, bottom left
        debugButton.onTap = { [weak self] in self?.showDebugLog() }
        debugButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(debugButton)
        NSLayoutConstraint.activate([
            debugButton.widthAnchor.constraint(equalToConstant: 36),
            debugButton.heightAnchor.constraint(equalToConstant: 36),
            debugButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 8),
            debugButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8)
        ])
        NotificationCenter.default.addObserver(
            self, selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let frame = bridgeViewController?.view.frame, frame != loggedBridgeFrame {
            loggedBridgeFrame = frame
            DebugLog.add("web view frame \(frame)")
        }
    }

    private func showDebugLog() {
        let navigation = UINavigationController(rootViewController: DebugLogViewController())
        navigation.overrideUserInterfaceStyle = .dark
        present(navigation, animated: true)
    }

    /// The addresses may have been changed in the iOS Settings app meanwhile.
    @objc private func appWillEnterForeground() {
        DebugLog.add("will enter foreground")
        if AppSettings.stored != shownSettings {
            showBridge()
        }
    }

    private func showBridge() {
        let settings = AppSettings.stored
        shownSettings = settings
        let raw = AppSettings.rawStored
        DebugLog.add("showBridge: settings \(settings.map { "\($0.appURL.absoluteString) / \($0.authHost)" } ?? "nil (setup page)"), "
            + "raw '\(raw.appURL)' / '\(raw.authHost)'")

        if let old = bridgeViewController {
            old.willMove(toParent: nil)
            old.view.removeFromSuperview()
            old.removeFromParent()
        }

        let next = AppBridgeViewController(settings: settings)
        next.onSettingsSaved = { [weak self] in
            // not from within the web view's message callback
            DispatchQueue.main.async { self?.showBridge() }
        }
        addChild(next)
        let content: UIView = next.view
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        let safeArea = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: safeArea.topAnchor),
            content.bottomAnchor.constraint(equalTo: safeArea.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor)
        ])
        next.didMove(toParent: self)
        bridgeViewController = next
        loggedBridgeFrame = nil
        view.bringSubviewToFront(debugButton)
    }
}

/// The Capacitor web view with a few native touches:
/// server address from the settings (else the local setup page), swipe back/forward, pull to
/// refresh, an own offline page and the new design as default.
final class AppBridgeViewController: CAPBridgeViewController {
    /// nil = nothing configured yet, Capacitor shows the bundled setup page (www/index.html)
    let settings: AppSettings?
    var onSettingsSaved: (() -> Void)?

    private var navigationProxy: NavigationDelegateProxy?
    private let refreshControl = UIRefreshControl()

    init(settings: AppSettings?) {
        self.settings = settings
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("created in code by RootViewController")
    }

    override func instanceDescriptor() -> InstanceDescriptor {
        let descriptor = super.instanceDescriptor()
        if let settings = settings {
            // like server.url / server.allowNavigation in capacitor.config.json
            descriptor.serverURL = settings.appURL.absoluteString
            descriptor.allowedNavigationHostnames = descriptor.allowedNavigationHostnames + [settings.authHost]
        }
        return descriptor
    }

    /// User scripts and the setup message handler. Must run in capacitorDidLoad(): Capacitor replaces
    /// the userContentController of webViewConfiguration(for:) with its own, but loads the start page
    /// only later (viewDidLoad).
    private func installContentScripts(on contentController: WKUserContentController, localScheme: String) {
        // runs after Capacitor's own scripts (same injection time, added later)
        contentController.addUserScript(WKUserScript(
            source: AppScripts.hideCordova,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true))

        if let host = settings?.appURL.host {
            contentController.addUserScript(WKUserScript(
                source: AppScripts.preferNewDesign(onHost: host),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true))
        }

        // current values for the setup page
        let raw = AppSettings.rawStored
        contentController.addUserScript(WKUserScript(
            source: AppScripts.setupValues(localScheme: localScheme, appURL: raw.appURL,
                                           authHost: raw.authHost, configured: settings != nil),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true))

        let handler = SetupMessageHandler(localScheme: localScheme)
        handler.onSaved = { [weak self] in self?.onSettingsSaved?() }
        handler.onCancel = { [weak self] in
            guard let self = self, let settings = self.settings else { return }
            self.webView?.load(URLRequest(url: settings.appURL))
        }
        contentController.addScriptMessageHandler(handler, contentWorld: .page, name: SetupMessageHandler.name)
    }

    override func capacitorDidLoad() {
        super.capacitorDidLoad()
        guard let webView = webView, let config = bridge?.config else { return }

        DebugLog.add("capacitorDidLoad: serverURL \(config.serverURL), localURL \(config.localURL), "
            + "start \(config.appStartServerURL), allowNavigation \(config.allowedNavigationHostnames)")
        let contentController = webView.configuration.userContentController
        contentController.addUserScript(WKUserScript(
            source: DebugLog.consoleScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        contentController.add(DebugMessageHandler(), contentWorld: .page, name: DebugMessageHandler.name)
        installContentScripts(on: contentController,
                              localScheme: config.localURL.scheme ?? "capacitor")
        webView.allowsBackForwardNavigationGestures = true
        // Capacitor turns bouncing off, but the pull-to-refresh control needs it
        webView.scrollView.bounces = true
        webView.scrollView.alwaysBounceVertical = true

        // Wrap Capacitor's navigation delegate to show our offline page only for real connection errors
        // (server.errorPath would also fire for cancelled navigations, e.g. links opened in Safari).
        if let inner = webView.navigationDelegate {
            let proxy = NavigationDelegateProxy(inner: inner)
            proxy.onLoadEnded = { [weak self] in self?.refreshControl.endRefreshing() }
            proxy.onConnectionError = { webView in
                DebugLog.add("connection error -> offline page")
                webView.load(URLRequest(url: AppScripts.errorPageURL(localURL: config.localURL, appURL: config.serverURL)))
            }
            navigationProxy = proxy
            webView.navigationDelegate = proxy
            DebugLog.add("navigation proxy installed around \(type(of: inner))")
        } else {
            DebugLog.add("no navigation delegate to wrap")
        }

        refreshControl.tintColor = AppTheme.muted
        refreshControl.addTarget(self, action: #selector(pullToRefresh), for: .valueChanged)
        webView.scrollView.refreshControl = refreshControl
    }

    @objc private func pullToRefresh() {
        guard let webView = webView, let config = bridge?.config else {
            refreshControl.endRefreshing()
            return
        }
        // On a local page (offline / setup) go to the app, if there is one.
        if webView.url?.scheme == config.localURL.scheme {
            if let settings = settings {
                webView.load(URLRequest(url: settings.appURL))
            } else {
                webView.reload()
            }
            return
        }
        // WKWebView ignores beforeunload prompts, so ask natively before unsaved input is lost.
        webView.evaluateJavaScript(AppScripts.hasUnsavedChanges) { [weak self] result, _ in
            guard let self = self else { return }
            if (result as? Bool) == true {
                self.confirmReload()
            } else {
                self.webView?.reload()
            }
        }
    }

    private func confirmReload() {
        let alert = UIAlertController(
            title: "Ungespeicherte Änderungen",
            message: "Beim Neuladen gehen die ungespeicherten Änderungen verloren.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Abbrechen", style: .cancel) { [weak self] _ in
            self?.refreshControl.endRefreshing()
        })
        alert.addAction(UIAlertAction(title: "Neu laden", style: .destructive) { [weak self] _ in
            self?.webView?.reload()
        })
        present(alert, animated: true)
    }
}

/// Receives the setup page's form: window.webkit.messageHandlers.rpSetup.postMessage(...)
/// Only the bundled setup page may change the addresses, never the loaded web app.
@MainActor
final class SetupMessageHandler: NSObject, WKScriptMessageHandlerWithReply {
    static let name = "rpSetup"

    private let localScheme: String
    var onSaved: (() -> Void)?
    var onCancel: (() -> Void)?

    init(localScheme: String) {
        self.localScheme = localScheme
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.protocol == localScheme else {
            replyHandler(nil, "Nicht erlaubt.")
            return
        }
        guard let body = message.body as? [String: Any] else {
            replyHandler(nil, "Ungültige Nachricht.")
            return
        }

        switch body["action"] as? String {
        case "save":
            do {
                let settings = try AppSettings.validated(
                    appURL: body["appUrl"] as? String ?? "",
                    authHost: body["authHost"] as? String ?? "")
                settings.save()
                DebugLog.add("setup saved: \(settings.appURL.absoluteString) / \(settings.authHost)")
                replyHandler(true, nil)
                onSaved?()
            } catch {
                replyHandler(nil, error.localizedDescription)
            }
        case "cancel":
            replyHandler(true, nil)
            onCancel?()
        default:
            replyHandler(nil, "Unbekannte Aktion.")
        }
    }
}

/// Forwards everything to Capacitor's own navigation delegate and adds hooks for load end and
/// connection errors.
final class NavigationDelegateProxy: NSObject, WKNavigationDelegate {
    private weak var inner: WKNavigationDelegate?
    var onLoadEnded: (() -> Void)?
    var onConnectionError: ((WKWebView) -> Void)?

    init(inner: WKNavigationDelegate) {
        self.inner = inner
    }

    override func responds(to aSelector: Selector!) -> Bool {
        return super.responds(to: aSelector) || (inner?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let inner = inner, inner.responds(to: aSelector) {
            return inner
        }
        return super.forwardingTarget(for: aSelector)
    }

    // TEMPORARY debug logging of the navigation flow, all calls still go to Capacitor.

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url?.absoluteString ?? "nil"
        let frame = navigationAction.targetFrame.map { $0.isMainFrame ? "main" : "sub" } ?? "new window"
        let logged: (WKNavigationActionPolicy) -> Void = { policy in
            DebugLog.add("nav action \(policy == .allow ? "ALLOW" : "CANCEL") [\(frame), type \(navigationAction.navigationType.rawValue)] \(url)")
            decisionHandler(policy)
        }
        if inner?.webView?(webView, decidePolicyFor: navigationAction, decisionHandler: logged) == nil {
            logged(.allow)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let status = (navigationResponse.response as? HTTPURLResponse).map { "HTTP \($0.statusCode)" } ?? "no HTTP"
        DebugLog.add("nav response \(status) [\(navigationResponse.isForMainFrame ? "main" : "sub"), "
            + "\(navigationResponse.response.mimeType ?? "?"), canShow \(navigationResponse.canShowMIMEType)] "
            + "\(navigationResponse.response.url?.absoluteString ?? "nil")")
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        DebugLog.add("did start \(webView.url?.absoluteString ?? "nil")")
        inner?.webView?(webView, didStartProvisionalNavigation: navigation)
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        DebugLog.add("redirect to \(webView.url?.absoluteString ?? "nil")")
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        DebugLog.add("did commit \(webView.url?.absoluteString ?? "nil")")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DebugLog.add("did finish \(webView.url?.absoluteString ?? "nil"), opaque \(webView.isOpaque)")
        inner?.webView?(webView, didFinish: navigation)
        onLoadEnded?()
        logSnapshot(of: webView, label: "snapshot at finish")
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak webView] in
            if let webView = webView {
                self.logSnapshot(of: webView, label: "snapshot +5s")
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        DebugLog.add("did fail: \(DebugLog.describe(error))")
        inner?.webView?(webView, didFail: navigation, withError: error)
        handle(error, in: webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        DebugLog.add("did fail provisional: \(DebugLog.describe(error))")
        inner?.webView?(webView, didFailProvisionalNavigation: navigation, withError: error)
        handle(error, in: webView)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        DebugLog.add("web content process terminated")
        inner?.webViewWebContentProcessDidTerminate?(webView)
    }

    private func logSnapshot(of webView: WKWebView, label: String) {
        webView.evaluateJavaScript(DebugLog.snapshotScript) { result, error in
            if let error = error {
                DebugLog.add("\(label) failed: \(DebugLog.describe(error))")
            } else {
                DebugLog.add("\(label): \(result ?? "nil")")
            }
        }
    }

    private func handle(_ error: Error, in webView: WKWebView) {
        onLoadEnded?()
        let nsError = error as NSError
        // cancelled / interrupted loads (redirects, links handed to Safari) are no connection problem
        if nsError.domain == NSURLErrorDomain && nsError.code != NSURLErrorCancelled {
            onConnectionError?(webView)
        }
    }
}

enum AppScripts {
    /// Capacitor's native bridge always defines window.cordova (legacy shim). keycloak-js takes that
    /// as "running in Cordova" and switches to its Cordova adapter (redirect_uri http://localhost/,
    /// InAppBrowser login), so the silent SSO check never completes and the web app reloads forever.
    /// The app uses no Cordova plugins, so the shim goes.
    static let hideCordova = """
        (function () {
          try { delete window.cordova; delete window.Cordova; } catch (e) {}
        })();
        """

    /// Makes the new design the default in the app, also on the iPad where the web app would start
    /// with the old one. An explicit choice in the profile menu (localStorage rp-design) still wins.
    static func preferNewDesign(onHost host: String) -> String {
        return """
        (function () {
          try {
            if (location.hostname === \(jsLiteral(host)) && !localStorage.getItem('rp-design')) {
              localStorage.setItem('rp-design', 'new');
            }
          } catch (e) {}
        })();
        """
    }

    /// window.rpSetup for the bundled setup page (only on local pages, not in the web app).
    static func setupValues(localScheme: String, appURL: String, authHost: String, configured: Bool) -> String {
        return """
        if (location.protocol === \(jsLiteral(localScheme + ":"))) {
          window.rpSetup = { appUrl: \(jsLiteral(appURL)), authHost: \(jsLiteral(authHost)), configured: \(configured) };
        }
        """
    }

    /// True when a page component vetoes leaving the page (e.g. the planning notes with unsaved text).
    static let hasUnsavedChanges = """
        (function () {
          try {
            var event = new Event('beforeunload', { cancelable: true });
            window.dispatchEvent(event);
            return event.defaultPrevented;
          } catch (e) {
            return false;
          }
        })();
        """

    static func errorPageURL(localURL: URL, appURL: URL) -> URL {
        var components = URLComponents(url: localURL.appendingPathComponent("error.html"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "url", value: appURL.absoluteString)]
        return components?.url ?? localURL.appendingPathComponent("error.html")
    }

    /// A JavaScript string literal (JSON-encoded, so quotes and line breaks are escaped).
    private static func jsLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value), let literal = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return literal
    }
}
