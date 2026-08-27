//
//  CountDownButton.swift
//  ScriptWidget
//
//  Created by everettjf on 2021/2/27.
//

import SwiftUI
import Combine

struct CountDownButton: View {
    public let text: String
    public let waitSeconds: Int
    public let action: () -> Void
    
    @State private var leftSeconds: Int = 0
    @State private var timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var isTimerStart = false

    
    @ViewBuilder
    func getButtonText() -> some View {
        if isTimerStart{
            Text("\(leftSeconds)")
        } else {
            Text(LocalizedStringKey(text))
        }
    }
    
    var body: some View {
        Button(action: {
            if !isTimerStart {
                startTimer()
                self.isTimerStart = true
                
                self.action()
            }
        }) {
            getButtonText()
        }
        .font(.footnote)
        .foregroundStyle(.primary)
        .frame(minWidth: 80, minHeight: 40, alignment: .center)
        .onReceive(timer, perform: { _ in
            
            if self.leftSeconds == 0 {
                self.leftSeconds = waitSeconds
                self.isTimerStart = false
                self.stopTimer()
            } else {
                self.leftSeconds -= 1
                print("\(self.leftSeconds)")
            }
        })
        .disabled(self.isTimerStart)
        .accessibilityLabel(Text(LocalizedStringKey(text)))
        .accessibilityValue(isTimerStart ? "Available again in \(leftSeconds) seconds" : "Ready")
    }
    
    func stopTimer() {
        self.timer.upstream.connect().cancel()
    }
    
    func startTimer() {
        self.timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    }
}

#Preview("Countdown Button") {
    CountDownButton(text: "Sync", waitSeconds: 10) { }
        .padding()
}

#Preview("Countdown Button · Large Type") {
    CountDownButton(text: "Sync", waitSeconds: 10) { }
        .padding()
        .environment(\.dynamicTypeSize, .accessibility2)
}
