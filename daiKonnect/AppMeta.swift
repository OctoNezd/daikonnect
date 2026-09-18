/// The app's name, as shown in the interface. Debug builds carry a suffix so
/// they are distinguishable from a release install beside them.
struct AppMeta {
    #if DEBUG
    static let AppName = "daiKonnect Dev"
    #else
    static let AppName = "daiKonnect"
    #endif
}
