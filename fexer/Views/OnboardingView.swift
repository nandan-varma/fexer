import AVFoundation
import Photos
import SwiftUI

// MARK: - Onboarding (first-run permissions)

struct OnboardingView: View {
    let permissionsManager: PermissionsManager
    @State private var openFraction: Double = 0
    @State private var isRequesting = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                // Icon
                ApertureLogoView(openFraction: openFraction)
                    .frame(width: 160, height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 36, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                    )

                Spacer().frame(height: 28)

                Text("fexer")
                    .font(.system(size: 40, weight: .light))
                    .tracking(14)
                    .foregroundStyle(.white)

                Text("Professional Camera")
                    .font(.system(size: 13))
                    .tracking(1.5)
                    .foregroundStyle(.white.opacity(0.38))
                    .padding(.top, 6)

                Spacer().frame(height: 44)

                // Permission rows
                VStack(spacing: 0) {
                    ForEach(Array(permissionItems.enumerated()), id: \.offset) { idx, item in
                        PermissionRowView(item: item, granted: item.check(permissionsManager))
                        if idx < permissionItems.count - 1 {
                            Rectangle()
                                .fill(Color.white.opacity(0.07))
                                .frame(height: 0.5)
                                .padding(.leading, 58)
                        }
                    }
                }
                .background(Color.white.opacity(0.055))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                )
                .padding(.horizontal, 24)

                Spacer(minLength: 0)

                // CTA
                VStack(spacing: 12) {
                    Button(action: requestAll) {
                        Group {
                            if isRequesting {
                                ProgressView().progressViewStyle(.circular).tint(.black)
                            } else {
                                Text("Allow Access & Open Camera")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(.black)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                    }
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .disabled(isRequesting)

                    Text("You can change permissions in Settings at any time.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.28))
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 52)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            withAnimation(.spring(response: 0.8, dampingFraction: 0.7).delay(0.2)) {
                openFraction = 1
            }
        }
    }

    private func requestAll() {
        isRequesting = true
        Task {
            await permissionsManager.requestAllPermissions()
            await MainActor.run { isRequesting = false }
        }
    }
}

// MARK: - Permission data

private struct PermissionItem {
    let icon: String
    let title: String
    let desc: String
    let check: (PermissionsManager) -> Bool
}

private let permissionItems: [PermissionItem] = [
    .init(icon: "camera", title: "Camera", desc: "Capture photos and video", check: { $0.cameraStatus == .authorized }),
    .init(icon: "photo.on.rectangle", title: "Photos", desc: "Save captures to your library", check: { $0.photoLibraryStatus == .authorized }),
    .init(icon: "mic", title: "Microphone", desc: "Record audio with video", check: { $0.microphoneStatus == .authorized }),
    .init(icon: "location", title: "Location", desc: "Embed GPS coordinates in metadata", check: { $0.locationStatus == .authorizedWhenInUse || $0.locationStatus == .authorizedAlways })
]

private struct PermissionRowView: View {
    let item: PermissionItem
    let granted: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: item.icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 30, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                Text(item.desc)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.42))
            }

            Spacer()

            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18))
                .foregroundStyle(granted ? Color.green : Color.white.opacity(0.2))
                .animation(.spring(response: 0.3), value: granted)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

// MARK: - Camera access denied

struct CameraAccessDeniedView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 24) {
                Image(systemName: "camera.slash")
                    .font(.system(size: 60, weight: .thin))
                    .foregroundStyle(.white.opacity(0.45))

                VStack(spacing: 8) {
                    Text("Camera Access Denied")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)

                    Text("fexer requires camera access.\nEnable it in Settings to continue.")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.48))
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                }

                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Text("Open Settings")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 36)
                        .padding(.vertical, 14)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .padding(.horizontal, 40)
        }
        .preferredColorScheme(.dark)
    }
}
