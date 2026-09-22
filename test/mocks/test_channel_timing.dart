import 'package:libspiffy/src/models/channel_timing.dart';

/// The channel timing tests run under (bead libspiffy-ywbk): payments stop
/// and the server settles ten minutes before a channel's lock time, and a
/// channel must run at least an hour. Channel fixtures lock a day ahead.
final testChannelTiming =
    ChannelTiming(settlementMargin: const Duration(minutes: 10), minimumLifetime: const Duration(hours: 1));
