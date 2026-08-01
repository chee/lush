//
//  ContentView.swift
//  richtext
//
//  Created by chee on 2026-08-01.
//

import SwiftUI

struct ContentView: View {
    @Binding var document: richtextDocument

    var body: some View {
        TextEditor(text: $document.text)
    }
}

#Preview {
    ContentView(document: .constant(richtextDocument()))
}
