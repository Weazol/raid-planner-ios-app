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
final class RootViewController: UIViewController {
    private let bridgeViewController = AppBridgeViewController()

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AppTheme.background

        addChild(bridgeViewController)
        let content: UIView = bridgeViewController.view
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        let safeArea = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: safeArea.topAnchor),
            content.bottomAnchor.constraint(equalTo: safeArea.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor)
        ])
        bridgeViewController.didMove(toParent: self)
    }
}

/// The Capacitor web view with a few native touches:
/// swipe back/forward, pull to refresh, an own offline page and the new design as default.
final class AppBridgeViewController: CAPBridgeViewController {
    private var navigationProxy: NavigationDelegateProxy?
    private let refreshControl = UIRefreshControl()

    override func webViewConfiguration(for instanceConfiguration: InstanceConfiguration) -> WKWebViewConfiguration {
        let configuration = super.webViewConfiguration(for: instanceConfiguration)
        if let host = instanceConfiguration.serverURL.host {
            configuration.userContentController.addUserScript(WKUserScript(
                source: AppScripts.preferNewDesign(onHost: host),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true))
        }
        return configuration
    }

    override func capacitorDidLoad() {
        super.capacitorDidLoad()
        guard let webView = webView, let config = bridge?.config else { return }

        webView.allowsBackForwardNavigationGestures = true

        // Wrap Capacitor's navigation delegate to show our offline page only for real connection errors
        // (server.errorPath would also fire for cancelled navigations, e.g. links opened in Safari).
        if let inner = webView.navigationDelegate {
            let proxy = NavigationDelegateProxy(inner: inner)
            proxy.onLoadEnded = { [weak self] in self?.refreshControl.endRefreshing() }
            proxy.onConnectionError = { webView in
                webView.load(URLRequest(url: AppScripts.errorPageURL(localURL: config.localURL, appURL: config.serverURL)))
            }
            navigationProxy = proxy
            webView.navigationDelegate = proxy
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
        // On the local offline page a reload would only show it again: go to the app instead.
        if webView.url?.scheme == config.localURL.scheme {
            webView.load(URLRequest(url: config.serverURL))
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

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        inner?.webView?(webView, didFinish: navigation)
        onLoadEnded?()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        inner?.webView?(webView, didFail: navigation, withError: error)
        handle(error, in: webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        inner?.webView?(webView, didFailProvisionalNavigation: navigation, withError: error)
        handle(error, in: webView)
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
    /// Makes the new design the default in the app, also on the iPad where the web app would start
    /// with the old one. An explicit choice in the profile menu (localStorage rp-design) still wins.
    static func preferNewDesign(onHost host: String) -> String {
        let hostLiteral = (try? String(data: JSONEncoder().encode(host), encoding: .utf8)) ?? "\"\""
        return """
        (function () {
          try {
            if (location.hostname === \(hostLiteral) && !localStorage.getItem('rp-design')) {
              localStorage.setItem('rp-design', 'new');
            }
          } catch (e) {}
        })();
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
}
