import SwiftUI
import WebKit
import Combine

/// Hosts the TV's actual transfer UI, so browser and companion features cannot drift.
@MainActor final class TransferStudioModel: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    @Published var devices: [String: URL] = [:]
    @Published var message = "Leave DualScreenTV open on the Apple TV home screen."
    @Published var opened = false
    @Published var exportedFile: URL?
    let web: WKWebView
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var browsing = false
    private var origin: URL?
    private var downloads: [ObjectIdentifier: URL] = [:]

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        web.navigationDelegate = self; web.uiDelegate = self
        web.isOpaque = false; web.backgroundColor = .black
        web.scrollView.backgroundColor = .black
        web.allowsBackForwardNavigationGestures = true
        browser.delegate = self
    }
    func start() {
        guard !browsing else { return }
        browsing = true
        browser.searchForServices(ofType: "_http._tcp.", inDomain: "local.")
    }
    func stop() {
        browser.stop(); browsing = false
        services.forEach { $0.stop() }; services.removeAll(); devices.removeAll()
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard service.name.hasPrefix("DualScreenTV") else { return }
        services.append(service); service.delegate = self; service.resolve(withTimeout: 8)
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        devices.removeValue(forKey: service.name)
        services.removeAll { $0 == service }
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        message = "Discovery unavailable. Allow Local Network access in Settings, or enter the TV address below."
    }
    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let host = sender.hostName, sender.port > 0 else { return }
        var parts = URLComponents(); parts.scheme = "http"; parts.host = host; parts.port = sender.port
        if let url = parts.url, CompanionTransferAddress.parse(url.absoluteString) != nil { devices[sender.name] = url }
    }
    func open(_ url: URL) {
        guard let local = CompanionTransferAddress.parse(url.absoluteString) else {
            message = "Enter the local .local or Wi-Fi IP address shown on Apple TV."; return
        }
        origin = local; message = "Connecting…"; opened = true
        web.load(URLRequest(url: local))
    }
    func reconnect() { if let origin { open(origin) } }
    func close() { web.stopLoading(); web.loadHTMLString("", baseURL: nil); origin = nil; opened = false }
    private func allowed(_ url: URL) -> Bool {
        guard let origin else { return false }
        return url.scheme == origin.scheme && url.host == origin.host && url.port == origin.port
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if url.absoluteString == "about:blank" { decisionHandler(.allow); return }
        guard allowed(url) || url.scheme == "blob" else { decisionHandler(.cancel); return }
        decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let attachment = (navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased().contains("attachment") == true
        decisionHandler(attachment || !navigationResponse.canShowMIMEType ? .download : .allow)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { message = "" }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    private func failed(_ error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        message = "Cannot reach Apple TV. Keep DualScreenTV on its home screen on the same network, then tap Reconnect."
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        message = "The transfer page stopped. Tap Reconnect before trying again."
    }
    // WebKit supplies the native Files/photo picker for HTML file inputs on iPadOS.
    // Handle JS confirmations because save replacement must remain explicit.
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard var controller = webView.window?.rootViewController else { completionHandler(false); return }
        while let presented = controller.presentedViewController { controller = presented }
        let alert = UIAlertController(title: "DualScreenTV", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "Continue", style: .default) { _ in completionHandler(true) })
        controller.present(alert, animated: true)
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        do {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TransferExports").appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = (suggestedFilename as NSString).lastPathComponent
            let file = folder.appendingPathComponent(name.isEmpty || name == "." || name == ".." ? "DualScreenTV-backup" : name)
            downloads[ObjectIdentifier(download)] = file; completionHandler(file)
        } catch { message = "Cannot save export: \(error.localizedDescription)"; completionHandler(nil) }
    }
    func downloadDidFinish(_ download: WKDownload) {
        exportedFile = downloads.removeValue(forKey: ObjectIdentifier(download))
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        if let file = downloads.removeValue(forKey: ObjectIdentifier(download)) { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        message = "Export failed: \(error.localizedDescription)"
    }
}

private struct StudioWebView: UIViewRepresentable {
    let web: WKWebView
    func makeUIView(context: Context) -> WKWebView { web }
    func updateUIView(_ uiView: WKWebView, context: Context) { }
}
private struct ExportShareSheet: UIViewControllerRepresentable {
    let file: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [file], applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) { }
}
struct TransferStudioView: View {
    @StateObject private var model = TransferStudioModel()
    @AppStorage("companion.transferAddress") private var savedAddress = ""
    @State private var address = ""
    @State private var confirmingClose = false
    @State private var previousIdleTimer: Bool?
    @Environment(\.scenePhase) private var phase
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if model.opened {
                    if !model.message.isEmpty { Text(model.message).font(.callout).padding().frame(maxWidth: .infinity).background(.thinMaterial) }
                    StudioWebView(web: model.web)
                } else {
                    StudioPage(eyebrow: "Your personal gaming space", title: "Your library.\nReady when you are.", subtitle: "Bring your games to Apple TV. Manage artwork, names and saved progress in one place.") {
                        Text("Connect to your Apple TV").font(.system(.callout, design: .rounded)).foregroundStyle(.gray)
                        Text("Make yourself at home.").font(.title.bold())
                        Text("Leave DualScreenTV on its home screen. Select your TV below and enter the code beneath Add/Edit Games.").foregroundStyle(.secondary)
                        ForEach(model.devices.keys.sorted(), id: \.self) { name in
                            Button { if let url = model.devices[name] { connect(url) } } label: {
                                Label("Connect to \(name)", systemImage: "appletv")
                            }.buttonStyle(StudioButtonStyle(prominent: true))
                        }
                        if model.devices.isEmpty { Label("Looking for Apple TVs…", systemImage: "wifi").foregroundStyle(.secondary) }
                        Divider()
                        Text("Your TV address").font(.system(.callout, design: .rounded)).foregroundStyle(.gray)
                        TextField("Apple-TV.local:8765", text: $address).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                            .padding(18).background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.15)))
                        Button("Connect to Apple TV ↗") {
                            if let url = CompanionTransferAddress.parse(address) { connect(url) }
                            else { model.message = "Use the local address shown on Apple TV, such as Apple-TV.local:8765." }
                        }.buttonStyle(StudioButtonStyle(prominent: model.devices.isEmpty))
                        Text(model.message).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .background(Color(white: 0.045))
            .navigationTitle("Games & Backups").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if model.opened {
                    ToolbarItem(placement: .navigationBarLeading) { Button("Change TV") { confirmingClose = true } }
                    ToolbarItem(placement: .navigationBarTrailing) { Button("Reconnect") { confirmingClose = true } }
                }
            }
            .confirmationDialog("Leave the transfer page? Wait for uploads to finish first.", isPresented: $confirmingClose, titleVisibility: .visible) {
                Button("Reconnect") { model.reconnect() }
                Button("Change TV") { model.close() }
                Button("Cancel", role: .cancel) { }
            }
            .sheet(isPresented: Binding(get: { model.exportedFile != nil }, set: { if !$0 { model.exportedFile = nil } })) {
                if let file = model.exportedFile { ExportShareSheet(file: file) }
            }
            .onAppear {
                address = savedAddress; model.start(); updateIdleTimer()
                #if DEBUG
                let arguments = ProcessInfo.processInfo.arguments
                if let index = arguments.firstIndex(of: "-DSTVTransferAddress"), arguments.indices.contains(index + 1),
                   let url = CompanionTransferAddress.parse(arguments[index + 1]), !model.opened {
                    model.open(url)
                }
                #endif
            }
            .onChange(of: model.opened) { _ in updateIdleTimer() }
            .onChange(of: phase) { _ in updateIdleTimer() }
            .onDisappear { model.stop(); restoreIdleTimer() }
        }.preferredColorScheme(.dark)
    }
    private func updateIdleTimer() {
        if model.opened && phase == .active {
            if previousIdleTimer == nil { previousIdleTimer = UIApplication.shared.isIdleTimerDisabled }
            UIApplication.shared.isIdleTimerDisabled = true
        } else { restoreIdleTimer() }
    }
    private func restoreIdleTimer() {
        if let previousIdleTimer { UIApplication.shared.isIdleTimerDisabled = previousIdleTimer }
        previousIdleTimer = nil
    }
    private func connect(_ url: URL) {
        savedAddress = url.absoluteString; address = savedAddress; model.open(url)
    }
}
