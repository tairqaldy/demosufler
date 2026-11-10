// Signs an app bundle with an identity kept in a .p12 file, without any keychain.
//   sign-tool <identity.p12> <password file> <app bundle>
// It calls the code signing engine of Security.framework directly, the same one the
// `codesign` tool uses. `codesign` itself can only take identities from a keychain.
import Foundation
import Security

@_silgen_name("SecCodeSignerCreate")
func SecCodeSignerCreate(_ parameters: CFDictionary, _ flags: UInt32, _ signer: UnsafeMutablePointer<CFTypeRef?>) -> OSStatus

@_silgen_name("SecCodeSignerAddSignatureWithErrors")
func SecCodeSignerAddSignatureWithErrors(_ signer: CFTypeRef, _ code: SecStaticCode, _ flags: UInt32,
                                         _ errors: UnsafeMutablePointer<Unmanaged<CFError>?>?) -> OSStatus

func constant(_ name: String) -> CFString {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else {
        fatalError("missing \(name)")
    }
    return symbol.assumingMemoryBound(to: CFString.self).pointee
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let args = CommandLine.arguments
guard args.count == 4 else { fail("usage: sign-tool <identity.p12> <password file> <app>") }
guard let p12 = FileManager.default.contents(atPath: args[1]) else { fail("cannot read \(args[1])") }
let password = (try? String(contentsOfFile: args[2], encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

var items: CFArray?
let options: [String: Any] = [
    kSecImportExportPassphrase as String: password,
    kSecImportToMemoryOnly as String: true,   // never touch the person's keychains
]
let imported = SecPKCS12Import(p12 as CFData, options as CFDictionary, &items)
guard imported == errSecSuccess, let first = (items as? [[String: Any]])?.first,
      let identityRef = first[kSecImportItemIdentity as String] else {
    fail("cannot open the identity (\(imported))")
}
let identity = identityRef as! SecIdentity

var code: SecStaticCode?
guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: args[3]) as CFURL, [], &code) == errSecSuccess, let code else {
    fail("cannot open \(args[3])")
}
var signer: CFTypeRef?
let parameters: [CFString: Any] = [constant("kSecCodeSignerIdentity"): identity]
let created = SecCodeSignerCreate(parameters as CFDictionary, 0, &signer)
guard created == errSecSuccess, let signer else { fail("cannot create the signer (\(created))") }
var error: Unmanaged<CFError>?
let status = SecCodeSignerAddSignatureWithErrors(signer, code, 0, &error)
if status != errSecSuccess {
    fail("signing failed (\(status)) \(error.map { String(describing: $0.takeRetainedValue()) } ?? "")")
}
print("signed \(args[3])")
