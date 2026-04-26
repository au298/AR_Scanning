//
//  ContentView.swift
//  AR_Scanning
//
//  Created by 古田聖直 on 2026/04/21.
//

import SwiftUI

/// アプリのルートView（LiDARスキャン画面を表示する）
struct ContentView: View {
    var body: some View {
        // スキャン・保存・AR再生の全機能を持つメイン画面
        LiDARScanningView()
    }
}

#Preview {
    ContentView()
}
