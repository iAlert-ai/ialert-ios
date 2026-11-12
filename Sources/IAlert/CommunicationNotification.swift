#if canImport(Intents) && os(iOS)
import Foundation
import Intents
import UserNotifications

/// Turns notification content into an iOS communication notification: the sender's photo and
/// name in place of the app icon (the app icon becomes a small badge). Needs the app's
/// "Communication Notifications" capability and `INSendMessageIntent` in `NSUserActivityTypes`;
/// without them iOS shows the notification as usual.
enum CommunicationNotification {
    static func update(_ content: UNNotificationContent, sender: IAlertSender, avatar: Data?) async -> UNNotificationContent {
        let handle = INPersonHandle(value: sender.id ?? sender.name, type: .unknown)
        let person = INPerson(
            personHandle: handle,
            nameComponents: nil,
            displayName: sender.name,
            image: avatar.map { INImage(imageData: $0) },
            contactIdentifier: nil,
            customIdentifier: sender.id ?? sender.name
        )
        let intent = INSendMessageIntent(
            recipients: nil,
            outgoingMessageType: .outgoingMessageText,
            content: content.body,
            speakableGroupName: nil,
            conversationIdentifier: "ialert-sender-" + (sender.id ?? sender.name),
            serviceName: nil,
            sender: person,
            attachments: nil
        )
        intent.setImage(person.image, forParameterNamed: \.sender)

        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        try? await interaction.donate()

        return (try? content.updating(from: intent)) ?? content
    }

    static func download(_ avatar: String?) async -> Data? {
        guard let avatar, let url = URL(string: avatar), url.scheme == "https" else { return nil }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }
}
#endif
