import SwiftUI

struct StyleCategoryView: View {
    @Binding var selectedCategory: StyleCategory
    let hasSmartStyle: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if hasSmartStyle {
                    categoryChip(label: "Smart", systemImage: "sparkles", category: nil, isAI: true)
                }

                ForEach(StyleCategory.allCases) { category in
                    categoryChip(label: category.rawValue, systemImage: systemImage(for: category), category: category)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func categoryChip(label: String, systemImage: String, category: StyleCategory?, isAI: Bool = false) -> some View {
        let isSelected = category == selectedCategory

        return Button {
            if let cat = category {
                withAnimation(.easeInOut(duration: 0.15)) {
                    selectedCategory = cat
                }
                HapticManager.selectionChanged()
            }
        } label: {
            HStack(spacing: 4) {
                if isAI {
                    Image(systemName: systemImage)
                        .font(.system(size: 11))
                        .symbolEffect(.pulse)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 11))
                }
                Text(label)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(isSelected ? .black : .white.opacity(0.8))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Color.yellow : Color.white.opacity(0.15),
                        in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func systemImage(for category: StyleCategory) -> String {
        switch category {
        case .film: return "film"
        case .genre: return "camera.aperture"
        case .mood: return "heart"
        case .custom: return "slider.horizontal.3"
        }
    }
}
