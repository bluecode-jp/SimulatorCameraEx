//
//  SimCamWeb.h
//  SimCamInject
//
//  Camera for web pages (getUserMedia) in Safari and WKWebView.
//

/// Hook WKWebView creation so pages get the SimulatorCamera frames through
/// getUserMedia. No-op in processes without WebKit.
void SCInstallWebKitHooks(void);
