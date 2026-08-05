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
        .foregroundColor(.primary)
        .frame(width: 80, height: 40, alignment: .center)
        .buttonStyle(.bordered)
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
    }
    
    func stopTimer() {
        self.timer.upstream.connect().cancel()
    }
    
    func startTimer() {
        self.timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    }
}

struct CountDownButton_Previews: PreviewProvider {
    static var previews: some View {
        CountDownButton(text: "hello",waitSeconds: 10){
        }
        .previewLayout(.sizeThatFits)
        .preferredColorScheme(.light)
        CountDownButton(text: "hello",waitSeconds: 10) {
        }
        .previewLayout(.sizeThatFits)
        .preferredColorScheme(.dark)
    }
}
