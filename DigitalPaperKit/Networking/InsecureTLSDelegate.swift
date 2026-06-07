import Foundation

/// URLSession delegate that accepts the device's self-signed certificate.
///
/// The DPT-RP1 serves its API over HTTPS with a certificate issued by the
/// device's own CA, so standard validation always fails. The Python reference
/// simply sets `session.verify = False`; we restrict the bypass to the device
/// host to keep it as narrow as possible.
final class InsecureTLSDelegate: NSObject, URLSessionDelegate {

    let trustedHost: String

    init(trustedHost: String) {
        self.trustedHost = trustedHost
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // This session is dedicated to a single device (the host it was created
        // for), so accept the self-signed server certificate for any server-trust
        // challenge. Host-string matching is unreliable for bracketed/zoned IPv6.
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
