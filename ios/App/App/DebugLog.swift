import UIKit
import WebKit

/// TEMPORARY in-app debug log: native events (bridge, navigation, HTTP status) and the web page's
/// console / JS errors. Opened with the small bug button at the bottom left; the share button
/// hands the text to Mail, Notes, AirDrop, ...
final class DebugLog {
    static let changed = Notification.Name("RPDebugLogChanged")

    private static let lock = NSLock()
    private static var lines: [String] = []
    private static let maxLines = 1500
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func add(_ text: String) {
        lock.lock()
        let line = "\(formatter.string(from: Date())) \(text)"
        lines.append(line)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
        lock.unlock()
        NSLog("[RP] %@", line)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    static var text: String {
        lock.lock()
        defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }

    static func clear() {
        lock.lock()
        lines.removeAll()
        lock.unlock()
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        let url = nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String ?? "-"
        return "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription) (url \(url))"
    }

    /// Forwards console.*, JS errors, failed resources and page lifecycle of every frame.
    static let consoleScript = """
        (function () {
          if (window.__rpDebug) { return; }
          window.__rpDebug = true;
          var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.rpDebug;
          if (!handler) { return; }
          var where = window.top === window ? '' : '[frame ' + location.host + '] ';
          function fmt(value) {
            try {
              if (value instanceof Error) { return value.name + ': ' + value.message + (value.stack ? '\\n' + value.stack : ''); }
              if (value && typeof value === 'object') { return JSON.stringify(value); }
            } catch (e) {}
            return String(value);
          }
          function send(level, args) {
            try { handler.postMessage(where + level + ': ' + Array.prototype.map.call(args, fmt).join(' ').slice(0, 3000)); } catch (e) {}
          }
          ['log', 'info', 'warn', 'error', 'debug'].forEach(function (level) {
            var original = console[level];
            console[level] = function () {
              send('console.' + level, arguments);
              if (original) { original.apply(console, arguments); }
            };
          });
          window.addEventListener('error', function (event) {
            var target = event.target;
            if (target && target !== window && target.tagName) {
              send('resource-error', [target.tagName + ' ' + (target.src || target.href || '')]);
            } else {
              send('js-error', [(event.message || '') + ' @ ' + (event.filename || '') + ':' + (event.lineno || '') + ':' + (event.colno || ''),
                                event.error || '']);
            }
          }, true);
          window.addEventListener('unhandledrejection', function (event) { send('unhandled-rejection', [event.reason]); });
          send('page', ['script injected ' + location.href]);
          document.addEventListener('DOMContentLoaded', function () { send('page', ['DOMContentLoaded ' + location.href]); });
          window.addEventListener('load', function () { send('page', ['load ' + location.href]); });
        })();
        """

    /// What is actually on the page (blank screen hunting).
    static let snapshotScript = """
        (function () {
          var body = document.body;
          var root = document.querySelector('app-root');
          var design = null;
          try { design = localStorage.getItem('rp-design'); } catch (e) {}
          return JSON.stringify({
            href: location.href, readyState: document.readyState, title: document.title,
            elements: document.getElementsByTagName('*').length,
            appRootChildren: root ? root.children.length : null,
            bodySize: body ? body.scrollWidth + 'x' + body.scrollHeight : null,
            viewport: window.innerWidth + 'x' + window.innerHeight,
            text: body ? (body.innerText || '').replace(/\\s+/g, ' ').slice(0, 300) : null,
            design: design, cookies: document.cookie ? document.cookie.split(';').length : 0
          });
        })();
        """
}

/// Receives the console messages of consoleScript.
final class DebugMessageHandler: NSObject, WKScriptMessageHandler {
    static let name = "rpDebug"

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        DebugLog.add("JS \(message.body)")
    }
}

/// Small floating button that opens the log.
final class DebugButton: UIButton {
    var onTap: (() -> Void)?

    init() {
        super.init(frame: .zero)
        setTitle("🐞", for: .normal)
        titleLabel?.font = .systemFont(ofSize: 18)
        backgroundColor = UIColor(white: 0, alpha: 0.45)
        layer.cornerRadius = 18
        alpha = 0.8
        accessibilityLabel = "Debug-Log"
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
    }

    required init?(coder: NSCoder) {
        fatalError("created in code")
    }

    @objc private func tapped() {
        onTap?()
    }
}

/// Shows the log, live, with share and clear.
final class DebugLogViewController: UIViewController {
    private let textView = UITextView()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Debug-Log"
        view.backgroundColor = AppTheme.background

        textView.isEditable = false
        textView.backgroundColor = AppTheme.background
        textView.textColor = UIColor(white: 0.9, alpha: 1)
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "Schließen", style: .done, target: self, action: #selector(close))
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(barButtonSystemItem: .action, target: self, action: #selector(share(_:))),
            UIBarButtonItem(title: "Leeren", style: .plain, target: self, action: #selector(clear))
        ]

        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: DebugLog.changed, object: nil)
        refresh()
    }

    @objc private func refresh() {
        textView.text = DebugLog.text
        let end = NSRange(location: max(textView.text.utf16.count - 1, 0), length: 1)
        textView.scrollRangeToVisible(end)
    }

    @objc private func close() {
        dismiss(animated: true)
    }

    @objc private func clear() {
        DebugLog.clear()
    }

    @objc private func share(_ sender: UIBarButtonItem) {
        let activity = UIActivityViewController(activityItems: [DebugLog.text], applicationActivities: nil)
        activity.popoverPresentationController?.barButtonItem = sender
        present(activity, animated: true)
    }
}
