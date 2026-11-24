import CryptoKit
import Foundation

/// The certificates a user chose to trust for a host although the engine
/// judged them not valid, one profile's worth.
///
/// An exception names the exact leaf certificate by its SHA-256
/// fingerprint, never the host alone: "accept any certificate for this
/// host" would let anyone on the same network impersonate the site with a
/// certificate of their own. When the site's certificate changes, the error
/// comes back and the user decides again.
public struct CertificateExceptions: Codable, Equatable {
    /// Lowercased host -> lowercase hex fingerprints of trusted leaf certificates.
    public private(set) var hosts: [String: [String]]

    public init(hosts: [String: [String]] = [:]) {
        self.hosts = hosts
    }

    /// The lowercase hex SHA-256 of a DER-encoded certificate, the form both
    /// engines can compute from what they hand over.
    public static func fingerprint(ofDER der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    public func trusts(host: String, fingerprint: String) -> Bool {
        hosts[host.lowercased()]?.contains(fingerprint.lowercased()) ?? false
    }

    public func hasException(host: String) -> Bool {
        !(hosts[host.lowercased()] ?? []).isEmpty
    }

    public mutating func trust(host: String, fingerprint: String) {
        let key = host.lowercased()
        let value = fingerprint.lowercased()
        guard !key.isEmpty, !value.isEmpty else { return }
        var list = hosts[key] ?? []
        if !list.contains(value) { list.append(value) }
        hosts[key] = list
    }

    public mutating func remove(host: String) {
        hosts.removeValue(forKey: host.lowercased())
    }
}
