import MacSpaceSdk

/// Options for CLI runs: no saved choices, so every toggle and background task reads as off.
struct EmptyOptions: OptionStore {
    func bool(_ id: String) -> Bool { false }
    func string(_ id: String) -> String { "" }
    func isBackgroundTaskEnabled(_ id: String) -> Bool { false }
}
