//
//  LushWidgetBundle.swift
//  LushWidget
//
//  Created by chee on 2026-08-04.
//

import WidgetKit
import SwiftUI

@main
struct LushWidgetBundle: WidgetBundle {
    var body: some Widget {
        FolderContentWidget()
        NewNoteWidget()
        QuickNoteWidget()
        QuickNoteLockScreenWidget()
        NewNoteLockScreenWidget()
        if #available(iOS 18.0, macOS 15.0, *) {
            QuickNoteControlWidget()
            NewNoteControlWidget()
        }
    }
}
