import 'package:libspiffy/src/spv/block_header_chain.dart';
import 'package:libspiffy/src/storage/in_memory_wallet_storage.dart';

/// A header chain whose median time past is [time]: the network time a
/// refund claim waits for (bead libspiffy-lpjh), set by the test. Null is a
/// node that holds no header yet.
class FixedTimeHeaderChain extends BlockHeaderChain {
  DateTime? time;

  FixedTimeHeaderChain(this.time) : super(InMemoryWalletStorage());

  /// A chain whose median time past is now.
  FixedTimeHeaderChain.now() : this(DateTime.now());

  @override
  Future<DateTime?> medianTimePast() async => time;
}
