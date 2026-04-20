//
//  Item.swift
//  health-sync
//
//  Created by Alexey Panfilov on 20. 4. 2026..
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
