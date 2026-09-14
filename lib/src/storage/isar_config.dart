/// Configuration for isolate-aware Isar storage operations.
///
/// **Deprecated, has no effect** (audit 2026-09-14 S-21): no storage
/// operation ever consulted it or ran in an isolate. It is still accepted
/// where it used to be (`IsarWalletStorage(config:)`,
/// `LibSpiffyActorSystem.initialize(isolateConfig:)`) and will be removed.
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
@Deprecated('Has no effect: libspiffy never runs storage operations in an isolate. '
    'Will be removed.')
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

