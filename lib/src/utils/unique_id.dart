import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// A process-unique, restart-unique id of the form `<prefix>-<uuid v4>`.
///
/// For actor names and channel ids. Millisecond timestamps (the previous
/// scheme) repeat for calls made within one millisecond, and a repeated
/// actor name makes `spawn` throw (A-L1).
String uniqueId(String prefix) => '$prefix-${_uuid.v4()}';
