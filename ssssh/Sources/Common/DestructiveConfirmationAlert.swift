import SwiftUI

extension View {
    /// A destructive confirmation alert bound to an optional "item pending
    /// deletion" state: a Cancel button plus one destructive button titled
    /// `confirmTitle`, both of which clear `item` afterward.
    ///
    /// `.alert` instead of `.confirmationDialog`: a confirmationDialog
    /// renders as a popover with a tail pointing at its (here, ambiguous)
    /// anchor on iPad, and only gets a Cancel button for free if no button
    /// you supply has role `.cancel`. `.alert` is a plain centered modal on
    /// every device -- no tail -- and needs an explicit Cancel button
    /// either way, which keeps that behavior obvious rather than
    /// incidental.
    func destructiveConfirmationAlert<Item>(
        _ title: String,
        item: Binding<Item?>,
        confirmTitle: String = "Delete",
        message: @escaping (Item) -> Text,
        onConfirm: @escaping (Item) -> Void
    ) -> some View {
        alert(
            title,
            isPresented: Binding(
                get: { item.wrappedValue != nil },
                set: { if !$0 { item.wrappedValue = nil } }
            ),
            presenting: item.wrappedValue
        ) { value in
            Button("Cancel", role: .cancel) {
                item.wrappedValue = nil
            }
            Button(confirmTitle, role: .destructive) {
                onConfirm(value)
                item.wrappedValue = nil
            }
        } message: { value in
            message(value)
        }
    }
}
