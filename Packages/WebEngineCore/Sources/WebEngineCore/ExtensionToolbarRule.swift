/// Where an installed extension appears in a window's toolbar.
public enum ExtensionToolbarRule {
    /// Listed in the extensions menu over a tab: loaded by the engine that
    /// owns the install list, or, while it is on, given a button for this tab
    /// by the engine running the tab's page (an extension one engine cannot
    /// start can still run in the other's tabs).
    public static func listsInMenu(isLoaded: Bool, isEnabled: Bool, hasActionInTab: Bool) -> Bool {
        isLoaded || (isEnabled && hasActionInTab)
    }

    /// A pinned button: what the menu lists, except an extension not set up
    /// yet in the profile (`isSetUp` false; nil for an extension with nothing
    /// to set up). Its button would only start a setup the user did not ask
    /// for; the menu item still does, because choosing it is asking.
    public static func showsPinnedButton(isLoaded: Bool, isEnabled: Bool, hasActionInTab: Bool, isSetUp: Bool?) -> Bool {
        isSetUp != false && listsInMenu(isLoaded: isLoaded, isEnabled: isEnabled, hasActionInTab: hasActionInTab)
    }
}
