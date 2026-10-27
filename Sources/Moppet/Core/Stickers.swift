import SwiftUI

/// airi's emotion sticker pack (packages/stage-ui/src/assets/stickers, MIT)
/// reused directly: the chat avatar mirrors the pet's live state.
enum Stickers {
    static func name(for state: PetState) -> String {
        switch state {
        case .idle, .thinking: return "airi-happy"
        case .talking: return "airi-affectionate"
        case .scanning: return "airi-confused"
        case .cleaning: return "airi-surprised"
        case .celebrating: return "airi-celebrate"
        case .sad: return "airi-sad"
        case .sleeping: return "airi-tired"
        }
    }

    static func image(for state: PetState) -> NSImage? {
        guard let url = Bundle.module.url(
            forResource: name(for: state), withExtension: "png", subdirectory: "stickers"
        ) else { return nil }
        return NSImage(contentsOf: url)
    }
}

/// Chat header avatar: airi sticker that follows the pet state.
struct PetStickerAvatar: View {
    @State private var bus = PetBus.shared
    var size: CGFloat = 30

    var body: some View {
        Group {
            if let image = Stickers.image(for: bus.state) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: "pawprint.fill")
                    .foregroundStyle(Airi.primary)
            }
        }
        .frame(width: size, height: size)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: bus.state)
    }
}
