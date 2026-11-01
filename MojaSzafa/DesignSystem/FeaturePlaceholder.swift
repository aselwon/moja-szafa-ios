import SwiftUI

/// Honest scaffold for features implemented in subsequent tasks.
struct FeaturePlaceholder: View {
    let title: LocalizedStringKey
    let symbol: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label(title, systemImage: symbol)
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("foundation.featurePending")
                    .font(.body)
                    .foregroundStyle(Color("secondaryText"))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .foregroundStyle(Color("primaryText"))
        .background(Color("background"))
        .navigationTitle(title)
    }
}
