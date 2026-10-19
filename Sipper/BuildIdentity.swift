import Foundation

enum BuildIdentity {
    static func makePasswordStore() -> PasswordStore {
        let primary = KeychainPasswordStore()
        if isHeadsetTest {
            return ReadThroughPasswordStore(primary: primary,
                original: KeychainPasswordStore(service: "com.hybes.sipper.sip-account"))
        }
        return primary
    }

    #if SIPPER_BH71_TEST
    static let isHeadsetTest = true
    static let name = "Sipper BH71 Test"
    static let supportDirectory = "Sipper BH71 Test"
    static let keychainService = "com.hybes.sipper.bh71test.sip-account"
    static let browserHostName = "com.hybes.sipper.bh71test"
    #else
    static let isHeadsetTest = false
    static let name = "Sipper"
    static let supportDirectory = "Sipper"
    static let keychainService = "com.hybes.sipper.sip-account"
    static let browserHostName = "com.hybes.sipper"
    #endif
}
