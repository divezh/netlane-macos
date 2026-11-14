import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// The owner's release key (ECDSA P-256, SHA-256). Its private half is not on GitHub: the app and the root
/// helper accept an update only when Netlane-macos.zip.sig verifies with this key, so a stolen GitHub account
/// cannot ship code to installed Macs. The same key signs the server and the Windows client.
public enum ReleaseSignature {
    /// X || Y of the public key (netlane-release.pub in the repository).
    public static let publicKeyHex = "b5ca1516f75fb306721650eabc73d1e194bbc3140babb8b0347b6ffa7c741817"
        + "4cb1f46a37124412e3a6250857f0af3b9f9f5f27cc792bb48554f4f711b3d676"
    /// A signature from `openssl dgst -sha256 -sign` is DER and never longer than this.
    public static let maxSignatureBytes = 128

    /// True when `signature` (DER, as openssl writes it) is the owner's signature of `data`.
    /// Without CryptoKit (the Linux test build) nothing verifies.
    public static func verify(_ data: Data, signature: Data) -> Bool {
        guard signature.count <= maxSignatureBytes else { return false }
        #if canImport(CryptoKit)
        guard let raw = hexData(publicKeyHex),
              let key = try? P256.Signing.PublicKey(rawRepresentation: raw),
              let parsed = try? P256.Signing.ECDSASignature(derRepresentation: signature) else { return false }
        return key.isValidSignature(parsed, for: data)
        #else
        return false
        #endif
    }

    static func hexData(_ text: String) -> Data? {
        guard text.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }
}
