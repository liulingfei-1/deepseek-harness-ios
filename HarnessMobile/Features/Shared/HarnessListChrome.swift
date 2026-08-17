import SwiftUI
import UIKit

extension View {
    func harnessCompactListChrome() -> some View {
        listStyle(.plain)
            .listSectionSpacing(.compact)
            .environment(\.defaultMinListRowHeight, 44)
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: .systemBackground))
    }
}
