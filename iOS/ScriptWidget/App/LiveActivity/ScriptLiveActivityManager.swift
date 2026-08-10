//
//  ScriptLiveActivityManager.swift
//  ScriptWidget
//
//  Created by everettjf on 2022/9/25.
//

import Foundation
import ActivityKit


class ScriptLiveActivityManager {
    static let maximumStateBytes = 4 * 1_024

    @discardableResult
    func create(scriptName: String, scriptParameter: String, initialState: String = "") -> String? {
        if #available(iOS 16.2, *) {
            guard Self.isValidState(initialState) else { return nil }
            guard ActivityAuthorizationInfo().areActivitiesEnabled else { return nil }
            let initialContentState = ScriptLiveActivityAttributes.ScriptLiveActivityState(scriptState: initialState)
            let activityAttributes = ScriptLiveActivityAttributes(scriptName: scriptName, scriptParameter: scriptParameter)
            let activityContent = ActivityContent(state: initialContentState, staleDate: nil)

            do {
                let deliveryActivity = try Activity.request(attributes: activityAttributes, content: activityContent)
                print("Requested Live Activity \(String(describing: deliveryActivity.id)).")
                return deliveryActivity.id
            } catch (let error) {
                print("Error requesting Live Activity \(error.localizedDescription).")
            }
        }
        return nil
    }

    @available(iOS 16.2, *)
    func update(activityID: String, state: String, staleDate: Date? = nil) async -> Bool {
        guard Self.isValidState(state),
              let activity = Activity<ScriptLiveActivityAttributes>.activities.first(where: { $0.id == activityID }) else {
            return false
        }
        await activity.update(ActivityContent(
            state: .init(scriptState: state),
            staleDate: staleDate
        ))
        return true
    }

    @available(iOS 16.2, *)
    func end(
        activityID: String,
        finalState: String,
        dismissalPolicy: ActivityUIDismissalPolicy = .default
    ) async -> Bool {
        guard Self.isValidState(finalState),
              let activity = Activity<ScriptLiveActivityAttributes>.activities.first(where: { $0.id == activityID }) else {
            return false
        }
        await activity.end(
            ActivityContent(state: .init(scriptState: finalState), staleDate: nil),
            dismissalPolicy: dismissalPolicy
        )
        return true
    }

    @available(iOS 16.2, *)
    func endAll(finalState: String = "") async {
        guard Self.isValidState(finalState) else { return }
        for activity in Activity<ScriptLiveActivityAttributes>.activities {
            await activity.end(
                ActivityContent(state: .init(scriptState: finalState), staleDate: nil),
                dismissalPolicy: .default
            )
        }
    }

    static func isValidState(_ state: String) -> Bool {
        state.utf8.count <= maximumStateBytes
    }
}



let sharedLiveActivityManager = ScriptLiveActivityManager()
