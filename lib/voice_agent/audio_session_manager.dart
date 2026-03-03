import 'dart:io';

import 'package:audio_session/audio_session.dart';

class AudioSessionManager {
  static Future<void> configure() async {
    final session = await AudioSession.instance;

    if (Platform.isIOS) {
      // iOS-specific configuration - starts with EARPIECE (no defaultToSpeaker)
      await session.configure(
        AudioSessionConfiguration(
          avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
          avAudioSessionCategoryOptions:
              AVAudioSessionCategoryOptions.allowBluetooth,
          // NO defaultToSpeaker - audio goes to earpiece by default
          avAudioSessionMode: AVAudioSessionMode
              .voiceChat, // Use voiceChat for proper echo cancellation
          androidAudioAttributes: const AndroidAudioAttributes(
            contentType: AndroidAudioContentType.speech,
            flags: AndroidAudioFlags.none,
            usage: AndroidAudioUsage.assistant,
          ),
          androidAudioFocusGainType:
              AndroidAudioFocusGainType.gainTransientMayDuck,
          androidWillPauseWhenDucked: false,
        ),
      );
    } else {
      // Android configuration
      await session.configure(
        AudioSessionConfiguration(
          avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
          avAudioSessionCategoryOptions:
              AVAudioSessionCategoryOptions.allowBluetooth |
                  AVAudioSessionCategoryOptions.defaultToSpeaker,
          avAudioSessionMode: AVAudioSessionMode.videoChat,
          androidAudioAttributes: const AndroidAudioAttributes(
            contentType: AndroidAudioContentType.speech,
            flags: AndroidAudioFlags.none,
            usage: AndroidAudioUsage
                .assistant, // Use assistant mode: speaker output + echo cancellation
          ),
          androidAudioFocusGainType:
              AndroidAudioFocusGainType.gainTransientMayDuck,
          androidWillPauseWhenDucked: false,
        ),
      );
    }

    await session.setActive(true);
  }

  /// Force audio output to speaker (useful after playback starts on iOS)
  static Future<void> overrideToSpeaker() async {
    if (!Platform.isIOS) return;

    final session = await AudioSession.instance;
    // Re-configure to ensure speaker output with FULL VOLUME
    await session.configure(
      AudioSessionConfiguration(
        avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
        avAudioSessionCategoryOptions:
            AVAudioSessionCategoryOptions.defaultToSpeaker |
                AVAudioSessionCategoryOptions.allowBluetooth,
        // Use videoChat mode for louder speaker output instead of voiceChat
        avAudioSessionMode: AVAudioSessionMode.videoChat,
        androidAudioAttributes: const AndroidAudioAttributes(
          contentType: AndroidAudioContentType.speech,
          flags: AndroidAudioFlags.none,
          usage: AndroidAudioUsage.assistant,
        ),
        androidAudioFocusGainType:
            AndroidAudioFocusGainType.gainTransientMayDuck,
        androidWillPauseWhenDucked: false,
      ),
    );
  }

  /// Set audio output to earpiece (receiver) - default for phone calls
  static Future<void> setToEarpiece() async {
    if (!Platform.isIOS) return;

    final session = await AudioSession.instance;
    // Configure without defaultToSpeaker - routes to earpiece
    await session.configure(
      AudioSessionConfiguration(
        avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
        avAudioSessionCategoryOptions:
            AVAudioSessionCategoryOptions.allowBluetooth,
        // No defaultToSpeaker = routes to earpiece
        avAudioSessionMode: AVAudioSessionMode.voiceChat,
        androidAudioAttributes: const AndroidAudioAttributes(
          contentType: AndroidAudioContentType.speech,
          flags: AndroidAudioFlags.none,
          usage: AndroidAudioUsage.assistant,
        ),
        androidAudioFocusGainType:
            AndroidAudioFocusGainType.gainTransientMayDuck,
        androidWillPauseWhenDucked: false,
      ),
    );
  }

  static Future<void> deactivate() async {
    final session = await AudioSession.instance;
    await session.setActive(false);
  }
}
