import SwiftUI

/// Tabs across the top of a long settings page. Only the chosen part is laid out, so a page
/// with many sections opens at once instead of after a second's pause.
struct PageTabs<Tab: Hashable & CaseIterable & Identifiable>: View where Tab.AllCases: RandomAccessCollection {
    @Binding var selection: Tab
    let title: (Tab) -> LocalizedStringKey

    init(selection: Binding<Tab>, title: @escaping (Tab) -> LocalizedStringKey) {
        _selection = selection
        self.title = title
    }

    var body: some View {
        Picker(selection: $selection) {
            ForEach(Tab.allCases) { tab in
                Text(title(tab)).tag(tab)
            }
        } label: {
            EmptyView()
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }
}
