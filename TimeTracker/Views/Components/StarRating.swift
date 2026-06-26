import SwiftUI

/// Reusable 1–5 star control. `rating` is optional so it can represent "unrated".
/// Tapping a star sets the value; tapping the current value clears it.
struct StarRating: View {
    @Binding var rating: Int?
    var size: CGFloat = 18
    var interactive: Bool = true

    var body: some View {
        HStack(spacing: 3) {
            ForEach(1...5, id: \.self) { star in
                Image(systemName: (rating ?? 0) >= star ? "star.fill" : "star")
                    .font(.system(size: size))
                    .foregroundStyle((rating ?? 0) >= star ? .yellow : .secondary)
                    .onTapGesture {
                        guard interactive else { return }
                        rating = (rating == star) ? nil : star
                    }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rating")
        .accessibilityValue(rating.map { "\($0) of 5" } ?? "unrated")
    }
}
