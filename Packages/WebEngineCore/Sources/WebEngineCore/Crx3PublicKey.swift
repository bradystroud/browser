import Foundation

extension Crx3 {
    public struct VerifiedPackage: Sendable {
        public let archive: Data
        /// The RSA public key (DER SubjectPublicKeyInfo) the extension id is
        /// made from. A manifest's `key` field is its base64.
        public let publicKey: Data
    }

    /// `verifiedArchive`, and the developer key the check proved: the proof
    /// whose key hashes to `expectedID` and whose signature holds.
    public static func verifiedPackage(_ crx: Data, expectedID: String) throws -> VerifiedPackage {
        let archive = try verifiedArchive(crx, expectedID: expectedID)
        let header = try parse(crx)
        guard let proof = header.rsaProofs.first(where: { ChromeExtensionID.from(publicKey: $0.publicKey) == expectedID }) else {
            throw Crx3Error.signatureInvalid
        }
        return VerifiedPackage(archive: archive, publicKey: proof.publicKey)
    }
}
