# T064 required-reason API declaration

The app stores its onboarding-complete preference using
`@AppStorage("welcome.seen.v1")`, which uses `UserDefaults`. The app target's
`PrivacyInfo.xcprivacy` declares that required API category and reason `CA92.1`.
Xcode includes the manifest in the built app bundle.

This is a narrow required-reason API declaration. It is not a complete review of
data collected by the app or its dependencies, does not supply App Store privacy
label answers, and does not claim App Store review approval. Those disclosures
must be assessed and maintained separately from this manifest.

See Apple's [TN3183: Adding required reason API entries to your privacy
manifest](https://developer.apple.com/documentation/technotes/tn3183-adding-required-reason-api-entries-to-your-privacy-manifest).
