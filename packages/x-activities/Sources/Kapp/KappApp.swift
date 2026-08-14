import SwiftUI

@main
struct KappApp: App {
    var body: some Scene {
        WindowGroup("X Activities") {
            XActivitiesView()
                .frame(minWidth: 420, minHeight: 360)
        }
    }
}

private struct XActivitiesView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("X Activities", systemImage: "bubble.left.and.bubble.right")
                .font(.largeTitle.bold())
            Text("Open the parts of X you use to review conversations and saved activity.")
                .foregroundStyle(.secondary)
            activityLink("Notifications", path: "notifications", icon: "bell")
            activityLink("Bookmarks", path: "i/bookmarks", icon: "bookmark")
            activityLink("Messages", path: "messages", icon: "envelope")
            Spacer()
        }
        .padding(28)
    }

    private func activityLink(_ title: String, path: String, icon: String) -> some View {
        Link(destination: URL(string: "https://x.com/\(path)")!) {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}
