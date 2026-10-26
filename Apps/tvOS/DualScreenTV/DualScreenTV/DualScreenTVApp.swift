//
//  DualScreenTVApp.swift
//  DualScreenTV
//
//

import SwiftUI

@main
struct DualScreenTVApp: App {
    @State private var showingSplash = true
    var body: some Scene {
        WindowGroup {
            ZStack {
                LibraryView().ignoresSafeArea()
                if showingSplash {
                    Color.black.ignoresSafeArea()
                        .overlay { Image("BrandSplash").resizable().scaledToFit().accessibilityLabel("DualScreenTV") }
                        .transition(.opacity)
                }
            }
            .task {
                try? await Task.sleep(nanoseconds: 900_000_000)
                withAnimation(.easeOut(duration: 0.3)) { showingSplash = false }
            }
        }
    }
}
