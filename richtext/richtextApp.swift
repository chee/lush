//
//  richtextApp.swift
//  richtext
//
//  Created by chee on 2026-08-01.
//

import SwiftUI

@main
struct richtextApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: richtextDocument()) { file in
            ContentView(document: file.$document)
        }
    }
}
