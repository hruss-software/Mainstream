import SwiftUI

@main
struct MainApp: App {
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            // `-viewport 320x568` squeezes the UI into a smaller screen (e.g. Display Zoom on a mini)
            if let i = CommandLine.arguments.firstIndex(of: "-viewport"), i + 1 < CommandLine.arguments.count {
                let wh = CommandLine.arguments[i + 1].split(separator: "x").compactMap { Double($0) }
                ContentView()
                    .frame(width: wh.first ?? 320, height: wh.count > 1 ? wh[1] : 568)
                    .border(.red)
            } else {
                ContentView()
            }
            #else
            ContentView()
            #endif
        }
    }
}
