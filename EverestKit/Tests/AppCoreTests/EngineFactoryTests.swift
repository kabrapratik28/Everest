import RewriteCore
import Testing

@testable import AppCore

/// Which concrete engine backs which id is a branch, so it lives here rather
/// than in the app target. Getting it wrong is silent: an `MLXEngine` built
/// for `.apple` would carry an empty `repoID` and fail at download time with
/// a malformed-repository error, several screens away from the mistake.
@Test("every catalog id builds the engine that claims that id")
func everyCatalogEntryBuildsItsOwnEngine() {
    for spec in ModelCatalog.all {
        #expect(EngineFactory.live(for: spec.id).id == spec.id)
    }
}

/// Never `~/.cache/huggingface`.
///
/// `HubCache.default` is shared with every other tool on the machine, which
/// Settings could neither size honestly nor safely delete — "Delete model"
/// would remove weights some other program is using. This app owns its own
/// cache root under Application Support and deletes only inside it.
@Test("models live in a directory this app owns, not the shared Hugging Face cache")
func theModelStoreIsPrivateToThisApp() {
    let root = EngineFactory.modelStoreRoot

    let path = root.path(percentEncoded: false)

    #expect(Array(root.pathComponents.suffix(2)) == ["Everest", "Models"])
    #expect(path.contains("Application Support"))
    #expect(!path.contains(".cache/huggingface"))
}
