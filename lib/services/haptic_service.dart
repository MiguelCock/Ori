import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Haptic feedback events with their own distinct vibration patterns.
/// 
/// Each event type maps to a specific vibration pattern that provides
/// intuitive tactile feedback for different navigation scenarios.
/// Patterns are designed to be distinguishable by touch alone.
enum HapticEvent {
  /// Navigation started → long pulse confirms action
  navigationStarted,
  
  /// Turn instruction → short + long indicates impending turn
  turnInstruction,
  
  /// Destination reached → three pulses celebrate arrival
  destinationReached,
  
  /// Route recalculated → two medium pulses indicates path change
  routeRecalculated,
  
  /// Error or no route → two quick pulses alerts user
  error,
  
  /// Selection feedback → one soft pulse (same as before)
  selection,
}

/// Service for providing haptic feedback across the application.
/// 
/// This service bridges Flutter's haptic capabilities with a native platform
/// channel for more precise vibration control, with automatic fallback to
/// Flutter's standard HapticFeedback when the native channel is unavailable.
/// 
/// Key features:
/// - Custom vibration patterns for different navigation events
/// - Platform channel for device-specific vibration control
/// - Graceful fallback to Flutter's HapticFeedback
/// - Web platform detection (no haptics on web)
/// - Silent failure if device has no vibrator
class HapticService {
  /// Platform channel for communicating with native vibration API.
  /// 
  /// Method: 'vibrate' with pattern parameter
  /// The native implementation should support custom vibration patterns.
  static const MethodChannel _channel =
      MethodChannel('campus_guia/haptic');

  /// Triggers the haptic pattern associated with the given event.
  /// 
  /// This is the main entry point for all haptic feedback in the app.
  /// It attempts to use the native platform channel for precise pattern
  /// control, but gracefully falls back to Flutter's HapticFeedback
  /// if the channel is unavailable or fails.
  /// 
  /// Parameters:
  ///   [event] - The type of haptic event to trigger
  /// 
  /// Behavior:
  /// - On web: silently returns (no haptics supported)
  /// - On native: attempts to use custom vibration pattern
  /// - On failure: uses Flutter HapticFeedback as fallback
  /// - Always logs results for debugging purposes
  static Future<void> trigger(HapticEvent event) async {
    // Skip haptics on web platform
    if (kIsWeb) return;

    // Get the vibration pattern for this event
    // Pattern format: [pause, vibration, pause, vibration, ...] in milliseconds
    // First value is always the initial pause (typically 0)
    final List<int> pattern = _patternFor(event);

    try {
      // Attempt to use native platform channel for custom vibration
      final success = await _channel.invokeMethod<bool>(
        'vibrate',
        {'pattern': pattern},
      );
      debugPrint('HapticService: native vibrate returned: $success');
      if (success != true) {
        debugPrint('HapticService: native vibrate failed, using fallback');
        _fallback(event);
      }
    } on PlatformException catch (e) {
      // Platform channel error (e.g., plugin not installed)
      debugPrint('HapticService error: ${e.message}');
      _fallback(event);
    } catch (e) {
      // Generic fallback: channel not initialized or other error
      // Use Flutter's standard haptic feedback
      _fallback(event);
    }
  }

  /// Returns the vibration pattern for a given event.
  /// 
  /// Pattern format: [initial_pause, duration1, pause1, duration2, ...]
  /// All values in milliseconds.
  /// 
  /// Pattern design principles:
  /// - Navigation started: Long single pulse for confirmation
  /// - Turn instruction: Short + long for anticipation + action
  /// - Destination reached: Three pulses for celebration
  /// - Route recalculated: Two medium pulses for notification
  /// - Error: Two quick pulses for urgency
  /// - Selection: Single soft pulse for subtle feedback
  static List<int> _patternFor(HapticEvent event) {
    switch (event) {
      case HapticEvent.navigationStarted:
        // Long single pulse: confirms navigation has started
        return [0, 400];

      case HapticEvent.turnInstruction:
        // Short + long: warning followed by confirmation of turn
        return [0, 100, 100, 300];

      case HapticEvent.destinationReached:
        // Three pulses: celebratory pattern for arrival
        return [0, 200, 100, 200, 100, 200];

      case HapticEvent.routeRecalculated:
        // Two medium pulses: indicates path has changed
        return [0, 150, 150, 150];

      case HapticEvent.error:
        // Two quick pulses: urgent feedback for error conditions
        return [0, 80, 80, 80];

      case HapticEvent.selection:
        // Soft single pulse: subtle selection feedback
        return [0, 50];
    }
  }

  /// Fallback method using Flutter's HapticFeedback.
  /// 
  /// This is used when the native platform channel fails or is unavailable.
  /// Maps each HapticEvent to the most appropriate Flutter haptic type:
  /// - Heavy impact: For major events (navigation start, destination reached)
  /// - Medium impact: For notifications (turns, route changes)
  /// - Light impact: For subtle feedback (errors, selections)
  static void _fallback(HapticEvent event) {
    switch (event) {
      case HapticEvent.navigationStarted:
      case HapticEvent.destinationReached:
        // Strong feedback for significant events
        HapticFeedback.heavyImpact();
        break;
      case HapticEvent.turnInstruction:
      case HapticEvent.routeRecalculated:
        // Medium feedback for navigational notifications
        HapticFeedback.mediumImpact();
        break;
      case HapticEvent.error:
      case HapticEvent.selection:
        // Light feedback for minor interactions
        HapticFeedback.lightImpact();
        break;
    }
  }
}