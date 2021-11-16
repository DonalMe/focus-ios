/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import UIKit
import WebKit
import Telemetry
import PassKit
import Combine
import Glean

protocol BrowserState {
    var url: URL? { get }
    var isLoading: Bool { get }
    var canGoBack: Bool { get }
    var canGoForward: Bool { get }
    var estimatedProgress: Double { get }
}

protocol WebController {
    var delegate: WebControllerDelegate? { get set }
    var canGoBack: Bool { get }
    var canGoForward: Bool { get }

    func load(_ request: URLRequest)
}

protocol WebControllerDelegate: AnyObject {
    func webControllerDidStartProvisionalNavigation(_ controller: WebController)
    func webControllerDidStartNavigation(_ controller: WebController)
    func webControllerDidFinishNavigation(_ controller: WebController)
    func webControllerDidNavigateBack(_ controller: WebController)
    func webControllerDidNavigateForward(_ controller: WebController)
    func webControllerDidReload(_ controller: WebController)
    func webControllerURLDidChange(_ controller: WebController, url: URL)
    func webController(_ controller: WebController, didFailNavigationWithError error: Error)
    func webController(_ controller: WebController, didUpdateCanGoBack canGoBack: Bool)
    func webController(_ controller: WebController, didUpdateCanGoForward canGoForward: Bool)
    func webController(_ controller: WebController, didUpdateEstimatedProgress estimatedProgress: Double)
    func webController(_ controller: WebController, scrollViewWillBeginDragging scrollView: UIScrollView)
    func webController(_ controller: WebController, scrollViewDidEndDragging scrollView: UIScrollView)
    func webController(_ controller: WebController, scrollViewDidScroll scrollView: UIScrollView)
    func webController(_ controller: WebController, stateDidChange state: BrowserState)
    func webControllerShouldScrollToTop(_ controller: WebController) -> Bool
    func webController(_ controller: WebController, didUpdateTrackingProtectionStatus trackingStatus: TrackingProtectionStatus)
    func webController(_ controller: WebController, didUpdateFindInPageResults currentResult: Int?, totalResults: Int?)
}

class WebViewController: UIViewController, WebController {
    private enum ScriptHandlers: String, CaseIterable {
        case focusTrackingProtection
        case focusTrackingProtectionPostLoad
        case findInPageHandler
        case fullScreen
        case metadata
        case adsMessageHandler
    }

    private enum KVOConstants: String, CaseIterable {
        case URL = "URL"
        case canGoBack = "canGoBack"
        case canGoForward = "canGoForward"
    }

    weak var delegate: WebControllerDelegate?

    var adsTelemetryUrlList: [String] = [String]()
    var adsProviderName: String = ""
    
    var browserView: WKWebView!
    var onePasswordExtensionItem: NSExtensionItem!
    private var progressObserver: NSKeyValueObservation?
    private var urlObserver: NSKeyValueObservation?
    private var currentBackForwardItem: WKBackForwardListItem?
    private var trackingProtectionStatus = TrackingProtectionStatus.on(TPPageStats()) {
        didSet {
            delegate?.webController(self, didUpdateTrackingProtectionStatus: trackingProtectionStatus)
        }
    }

    private var trackingInformation = TPPageStats() {
        didSet {
            if case .on = trackingProtectionStatus {
                trackingProtectionStatus = .on(trackingInformation)
            }
        }
    }

    var pageTitle: String? {
        return browserView.title
    }
    
    private var currentContentMode: WKWebpagePreferences.ContentMode?
    private var contentModeForHost: [String: WKWebpagePreferences.ContentMode] = [:]

    var requestMobileSite: Bool { currentContentMode == .desktop }    
    var connectionIsSecure: Bool {
        return browserView.hasOnlySecureContent
    }

    var printFormatter: UIPrintFormatter { return browserView.viewPrintFormatter() }
    var scrollView: UIScrollView { return browserView.scrollView }

    convenience init() {
        self.init(nibName: nil, bundle: nil)
        setupWebview()
        ContentBlockerHelper.shared.handler = reloadBlockers(_:)
    }
    
    func reset() {
        browserView.load(URLRequest(url: URL(string: "about:blank")!))
        browserView.navigationDelegate = nil
        browserView.removeFromSuperview()
        trackingProtectionStatus = .on(TPPageStats())
        setupWebview()
        self.browserView.addObserver(self, forKeyPath: "URL", options: .new, context: nil)
    }

    // Browser proxy methods
    func load(_ request: URLRequest) { browserView.load(request) }
    func goBack() { browserView.goBack() }
    func goForward() { browserView.goForward() }
    func reload() { browserView.reload() }

    func requestUserAgentChange() {
        if let hostName = browserView.url?.host {
            contentModeForHost[hostName] = requestMobileSite ? .mobile : .desktop
        }
        
        self.browserView.reloadFromOrigin()
    }

    func stop() { browserView.stopLoading() }

    private func setupWebview() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        configuration.allowsInlineMediaPlayback = true
        
        // For consistency we set our user agent similar to Firefox iOS.
        //
        // Important to note that this UA change only applies when the webview is created initially or
        // when people hit the erase session button. The UA is not changed when you change the width of
        // Focus on iPad, which means there could be some edge cases right now.
        
        if UIDevice.current.userInterfaceIdiom == .pad {
            configuration.applicationNameForUserAgent = "Version/13.1 Safari/605.1.15"
        } else {
            configuration.applicationNameForUserAgent = "FxiOS/\(AppInfo.majorVersion) Mobile/15E148 Version/15.0"
        }
                
        if #available(iOS 15.0, *) {
            configuration.upgradeKnownHostsToHTTPS = true
        }
        browserView = WKWebView(frame: .zero, configuration: configuration)

        browserView.allowsBackForwardNavigationGestures = true
        browserView.allowsLinkPreview = true
        browserView.scrollView.clipsToBounds = false
        browserView.scrollView.delegate = self
        browserView.navigationDelegate = self
        browserView.uiDelegate = self

        progressObserver = browserView.observe(\WKWebView.estimatedProgress) { (webView, value) in
            self.delegate?.webController(self, didUpdateEstimatedProgress: webView.estimatedProgress)
        }

        setupBlockLists()
        setupTrackingProtectionScripts()
        setupFindInPageScripts()
        setupMetadataScripts()
        setupAdsScripts()
        setupFullScreen()

        view.addSubview(browserView)
        browserView.snp.makeConstraints { make in
            make.edges.equalTo(view.snp.edges)
        }

        KVOConstants.allCases.forEach { browserView.addObserver(self, forKeyPath: $0.rawValue, options: .new, context: nil) }
    }

    @objc private func reloadBlockers(_ blockLists: [WKContentRuleList]) {
        DispatchQueue.main.async {
            self.browserView.configuration.userContentController.removeAllContentRuleLists()
            blockLists.forEach(self.browserView.configuration.userContentController.add)
        }
    }

    private func setupBlockLists() {
        ContentBlockerHelper.shared.getBlockLists { lists in
            self.reloadBlockers(lists)
        }
    }

    private func addScript(forResource resource: String, injectionTime: WKUserScriptInjectionTime, forMainFrameOnly mainFrameOnly: Bool) {
        let source = try! String(contentsOf: Bundle.main.url(forResource: resource, withExtension: "js")!)
        let script = WKUserScript(source: source, injectionTime: injectionTime, forMainFrameOnly: mainFrameOnly)
        browserView.configuration.userContentController.addUserScript(script)
    }

    private func setupTrackingProtectionScripts() {
        browserView.configuration.userContentController.add(self, name: ScriptHandlers.focusTrackingProtection.rawValue)
        addScript(forResource: "preload", injectionTime: .atDocumentStart, forMainFrameOnly: true)
        browserView.configuration.userContentController.add(self, name: ScriptHandlers.focusTrackingProtectionPostLoad.rawValue)
        addScript(forResource: "postload", injectionTime: .atDocumentEnd, forMainFrameOnly: false)
    }

    private func setupFindInPageScripts() {
        browserView.configuration.userContentController.add(self, name: ScriptHandlers.findInPageHandler.rawValue)
        addScript(forResource: "FindInPage", injectionTime: .atDocumentEnd, forMainFrameOnly: true)
    }
    
    private func setupMetadataScripts() {
        browserView.configuration.userContentController.add(self, name: ScriptHandlers.metadata.rawValue)
        addScript(forResource: "MetadataHelper", injectionTime: .atDocumentEnd, forMainFrameOnly: true)
    }
    
    private func setupAdsScripts() {
        browserView.configuration.userContentController.add(self, name: ScriptHandlers.adsMessageHandler.rawValue)
        addScript(forResource: "Ads", injectionTime: .atDocumentStart, forMainFrameOnly: true) // TODO Are injectionTime and forMainFrameOnly correct here?
    }
    
    private func setupFullScreen() {
        browserView.configuration.userContentController.add(self, name: ScriptHandlers.fullScreen.rawValue)
        addScript(forResource: "FullScreen", injectionTime: .atDocumentEnd, forMainFrameOnly: true)
    }

    func disableTrackingProtection() {
        guard case .on = trackingProtectionStatus else { return }
        ScriptHandlers.allCases.forEach {
            browserView.configuration.userContentController.removeScriptMessageHandler(forName: $0.rawValue)
        }
        browserView.configuration.userContentController.removeAllUserScripts()
        browserView.configuration.userContentController.removeAllContentRuleLists()
        setupFindInPageScripts()
        setupMetadataScripts()
        setupAdsScripts()
        trackingProtectionStatus = .off
    }

    func enableTrackingProtection() {
        guard case .off = trackingProtectionStatus else { return }

        setupBlockLists()
        setupTrackingProtectionScripts()
        trackingProtectionStatus = .on(TPPageStats())
    }

    func evaluate(_ javascript: String, completion: ((Any?, Error?) -> Void)?) {
        browserView.evaluateJavaScript(javascript, completionHandler: completion)
    }
    
    enum MetadataError: Swift.Error {
        case missingMetadata
        case missingURL
    }

    /// Get the metadata out of the page-metadata-parser, and into a type safe struct as soon as possible.
    /// 
    func getMetadata(completion: @escaping (Swift.Result<Metadata, Error>) -> Void) {
        evaluate("__firefox__.metadata.getMetadata()") { result, error in
            let metadata = result
                .flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                .flatMap { try? JSONDecoder().decode(Metadata.self, from: $0) }
            
            if let metadata = metadata {
                completion(.success(metadata))
            } else if let error = error {
                completion(.failure(error))
            } else {
                completion(.failure(MetadataError.missingMetadata))
            }
        }
    }
    
    func getMetadata()  -> Future<Metadata, Error> {
        Future { promise in
            self.getMetadata { result in
                promise(result)
            }
        }
    }

    func focus() {
        browserView.becomeFirstResponder()
    }
    
    func resetZoom() {
        browserView.scrollView.setZoomScale(1.0, animated: true)
    }

    override func viewDidLoad() {
        self.browserView.addObserver(self, forKeyPath: "URL", options: .new, context: nil)
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard let kp = keyPath, let path = KVOConstants(rawValue: kp) else {
            assertionFailure("Unhandled KVO key: \(keyPath ?? "nil")")
            return
        }

        switch path {
        case .URL:
            guard let url = browserView.url else { break }
            delegate?.webControllerURLDidChange(self, url: url)
        case .canGoBack:
            guard let canGoBack = change?[.newKey] as? Bool else { break }
            delegate?.webController(self, didUpdateCanGoBack: canGoBack)
        case .canGoForward:
            guard let canGoForward = change?[.newKey] as? Bool else { break }
            delegate?.webController(self, didUpdateCanGoForward: canGoForward)
        }
    }
}

extension WebViewController: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        delegate?.webController(self, scrollViewDidScroll: scrollView)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        delegate?.webController(self, scrollViewWillBeginDragging: scrollView)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        delegate?.webController(self, scrollViewDidEndDragging: scrollView)
    }

    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        return delegate?.webControllerShouldScrollToTop(self) ?? true
    }
}

extension WebViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        delegate?.webControllerDidStartNavigation(self)
        if case .on = trackingProtectionStatus { trackingInformation = TPPageStats() }
        currentContentMode = navigation?.effectiveContentMode
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        delegate?.webControllerDidFinishNavigation(self)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        delegate?.webController(self, didFailNavigationWithError: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let error = error as NSError
        guard error.code != Int(CFNetworkErrors.cfurlErrorCancelled.rawValue), let errorUrl = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL else { return }
        let errorPageData = ErrorPage(error: error).data
        webView.load(errorPageData, mimeType: "", characterEncodingName: UIConstants.strings.encodingNameUTF8, baseURL: errorUrl)
    }
    
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences, decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        // If the user has asked for a specific content mode for this host, use that.
        if let hostName = navigationAction.request.url?.host, let preferredContentMode = contentModeForHost[hostName] {
            preferences.preferredContentMode = preferredContentMode
        }
        
        let present: (UIViewController) -> Void = {
            self.present($0, animated: true) {
                self.delegate?.webController(self, didUpdateEstimatedProgress: 1.0)
                self.delegate?.webControllerDidFinishNavigation(self)
            }
        }

        switch navigationAction.navigationType {
            case .backForward:
                let navigatingBack = webView.backForwardList.backList.filter { $0 == currentBackForwardItem }.count == 0
                if navigatingBack {
                    delegate?.webControllerDidNavigateBack(self)
                } else {
                    delegate?.webControllerDidNavigateForward(self)
                }
            case .reload:
                delegate?.webControllerDidReload(self)
            case .linkActivated:
                if let url = navigationAction.request.url, adsTelemetryUrlList.count > 0 {
                    if adsTelemetryUrlList.contains(url.absoluteString) {
                        if !adsProviderName.isEmpty {
                            GleanMetrics.BrowserSearch.adClicks["provider-\(adsProviderName)"].add()
                        }
                        adsTelemetryUrlList.removeAll()
                        adsProviderName = ""
                    }
                }
            default:
                break
        }

        currentBackForwardItem = webView.backForwardList.currentItem

        // prevent Focus from opening universal links
        // https://stackoverflow.com/questions/38450586/prevent-universal-links-from-opening-in-wkwebview-uiwebview
        let allowDecision = WKNavigationActionPolicy(rawValue: WKNavigationActionPolicy.allow.rawValue + 2) ?? .allow

        let decision: WKNavigationActionPolicy = RequestHandler().handle(request: navigationAction.request, alertCallback: present) ? allowDecision : .cancel
        if navigationAction.navigationType == .linkActivated && browserView.url != navigationAction.request.url {
            Telemetry.default.recordEvent(category: TelemetryEventCategory.action, method: TelemetryEventMethod.click, object: TelemetryEventObject.websiteLink)
        }
        
        decisionHandler(decision, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let response = navigationResponse.response

        guard let responseMimeType = response.mimeType else {
            decisionHandler(.allow)
            return
        }

        // Check for passbook response
        if responseMimeType == "application/vnd.apple.pkpass" {
            decisionHandler(.allow)
            browserView.load(URLRequest(url: URL(string: "about:blank")!))

            func presentPassErrorAlert() {
                let passErrorAlert = UIAlertController(title: UIConstants.strings.addPassErrorAlertTitle, message: UIConstants.strings.addPassErrorAlertMessage, preferredStyle: .alert)
                let passErrorDismissAction = UIAlertAction(title: UIConstants.strings.addPassErrorAlertDismiss, style: .default) { (UIAlertAction) in
                    passErrorAlert.dismiss(animated: true, completion: nil)
                }
                passErrorAlert.addAction(passErrorDismissAction)
                self.present(passErrorAlert, animated: true, completion: nil)
            }

            guard let responseURL = response.url else {
                presentPassErrorAlert()
                return
            }

            guard let passData = try? Data(contentsOf: responseURL) else {
                presentPassErrorAlert()
                return
            }

            guard let pass = try? PKPass(data: passData) else {
                // Alert user to add pass failure
                presentPassErrorAlert()
                return
            }

            // Present pass
            let passLibrary = PKPassLibrary()
            if passLibrary.containsPass(pass) {
                UIApplication.shared.open(pass.passURL!, options: [:])
            } else {
                guard let addController = PKAddPassesViewController(pass: pass) else {
                    presentPassErrorAlert()
                    return
                }
                self.present(addController, animated: true, completion: nil)
            }

            return
        }

        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        delegate?.webControllerDidStartProvisionalNavigation(self)
    }
}

extension WebViewController: BrowserState {
    var canGoBack: Bool { return browserView.canGoBack }
    var canGoForward: Bool { return browserView.canGoForward }
    var estimatedProgress: Double { return browserView.estimatedProgress }
    var isLoading: Bool { return browserView.isLoading }
    var url: URL? { return browserView.url }
}

extension WebViewController: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            browserView.load(navigationAction.request)
        }

        return nil
    }
}

extension WebViewController: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "adsMessageHandler" {
            guard let provider = getProviderForMessage(message: message), let body = message.body as? [String : Any], let urls = body["urls"] as? [String] else {
                return
            }
            
            let adUrls = provider.listAdUrls(urls: urls)
            
            if !adUrls.isEmpty {
                GleanMetrics.BrowserSearch.withAds["provider-\(provider.name)"].add()
                adsProviderName = provider.name
                adsTelemetryUrlList = adUrls
            }
            
            return
        }
        
        if message.name == "findInPageHandler" {
            let data = message.body as! [String: Int]

            // We pass these separately as they're sent in different messages to the userContentController
            if let currentResult = data["currentResult"] {
                delegate?.webController(self, didUpdateFindInPageResults: currentResult, totalResults: nil)
            }

            if let totalResults = data["totalResults"] {
                delegate?.webController(self, didUpdateFindInPageResults: nil, totalResults: totalResults)
            }
            
            return
        }

        // Unclear what the difference is, but these two were previously the 'fall-through'
        if message.name == "focusTrackingProtection" || message.name == "focusTrackingProtectionPostLoad" {
            guard let body = message.body as? [String: String],
                let urlString = body["url"],
                var components = URLComponents(string: urlString) else {
                    return
            }

            components.scheme = "http"
            guard let url = components.url else { return }

            let enabled = Utils.getEnabledLists().compactMap { BlocklistName(rawValue: $0) }
            TPStatsBlocklistChecker.shared.isBlocked(url: url, enabledLists: enabled).uponQueue(.main) { listItem in
                if let listItem = listItem {
                    self.trackingInformation = self.trackingInformation.create(byAddingListItem: listItem)
                }
            }
        }
    }
}

// Ad Telemetry Helper

extension WebViewController {
    private func getProviderForMessage(message: WKScriptMessage) -> SearchProviderModel? {
        guard let body = message.body as? [String : Any], let url = body["url"] as? String else { return nil }
        for provider in SearchProviderModel.searchProviderList {
            if url.range(of: provider.regexp, options: .regularExpression) != nil {
                return provider
            }
        }
        return nil
    }
}
