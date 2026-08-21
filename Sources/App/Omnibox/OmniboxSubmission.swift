import Foundation

/// What the omnibox does with what was typed (browser-0du). The decision
/// itself is SearchCore's `OmniboxResolver`, which is pure and tested; this
/// is only the app-side wiring that supplies it with the chosen engine and
/// the profile's Quick Website Search keywords.
enum OmniboxSubmission {
    static func resolve(_ text: String, profile: Profile) -> String? {
        switch OmniboxResolver.resolve(
            input: text,
            engine: SearchEnginePreference.current,
            quickSites: quickSites(for: profile)
        ) {
        case .navigate(let url): return url
        case .nothing: return nil
        }
    }

    /// Empty unless Quick Website Search is switched on -- an empty list is
    /// how "the feature is off" reaches the resolver, which has no opinion
    /// about settings.
    ///
    /// Private windows are not excluded. The keywords come from history that
    /// is already on disk and were not learned from this window's browsing
    /// (a private window records no visits at all), and nothing leaves the
    /// machine until the user presses Return -- the same terms as the
    /// history autocomplete a private window already offers.
    static func quickSites(for profile: Profile) -> [QuickSiteSearchSite] {
        guard SearchEnginePreference.quickSiteSearchEnabled else { return [] }
        let history = ProfileDataStoreManager.shared.stores(for: profile).history
        return QuickSiteSearchCatalog.shared.sites(profileId: profile.id, history: history)
    }
}
