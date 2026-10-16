import Foundation

// Bring-your-own-key: the user's provider keys live in this Mac's Keychain and
// requests go straight to the chosen provider.
extension ModelService {
    static func direct(configuration: Configuration, session: URLSession = ModelService.defaultSession) throws -> ModelService {
        return ModelService(configuration: configuration,
                            sttKey: try Keychain.read(Keychain.account(endpoint: configuration.sttURL)),
                            rewriteKey: try Keychain.read(Keychain.account(endpoint: configuration.rewriteURL)), session: session)
    }
}
