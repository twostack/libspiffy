/// Configuration for isolate-aware Isar storage operations.
///
/// This class controls when heavy database operations should be
/// executed in separate isolates to avoid blocking the UI thread.
///
/// Example usage:
/// ```dart
/// // Default configuration (enabled with threshold of 100)
/// final config = IsolateConfig.defaultConfig();
///
/// // Custom threshold
/// final customConfig = IsolateConfig(
///   operationThreshold: 50,
///   enabled: true,
/// );
///
/// // Disable isolates
/// final disabledConfig = IsolateConfig.disabled();
/// ```
class IsolateConfig {
  /// Threshold for switching to isolate-based operations.
  /// Operations affecting more items than this threshold will use isolates.
  final int operationThreshold;

  /// Whether isolate support is enabled at all.
  /// If false, all operations run in the main isolate.
  final bool enabled;

  const IsolateConfig({
    required this.operationThreshold,
    required this.enabled,
  });

  /// Default configuration with isolates enabled and threshold of 100 items.
  factory IsolateConfig.defaultConfig() => const IsolateConfig(
        operationThreshold: 100,
        enabled: true,
      );

  /// Configuration with isolates completely disabled.
  /// All operations will run in the main isolate.
  factory IsolateConfig.disabled() => const IsolateConfig(
        operationThreshold: 0,
        enabled: false,
      );

  /// Check if an operation should use an isolate based on operation size.
  bool shouldUseIsolate(int operationSize) {
    return enabled && operationSize > operationThreshold;
  }

  @override
  String toString() {
    return 'IsolateConfig(enabled: $enabled, threshold: $operationThreshold)';
  }
}

