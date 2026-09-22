/// Static guard for audit finding A-H2 (doc/audit-2026-09-14.md).
///
/// Every `ask(AwaitEventApplied(...))` site must pass an explicit ask
/// timeout that is longer than the awaiter's own `timeout:` window.
/// Otherwise dactor's default 5 s ask timeout fires before the projection
/// awaiter (10-30 s) does, and a slow-but-successful projection is reported
/// as a failure (payment recorded but reply says failed, invoice/channel
/// created but caller told otherwise).
///
/// The invoice path is also covered behaviourally in
/// invoice_coordinator_actor_test.dart; the payment and wallet-coordinator
/// sites sit too deep in the payment flow to drive cheaply, so this scan
/// keeps every site honest (seven at the audit; three more channel-manager sites were added by the funding-broadcast fix, libspiffy-9f7; libspiffy-fsy folded the four channel-manager sites into one `_awaitApplied` helper; libspiffy-u0x folded the two invoice-creation sites into `_createInAggregate`; libspiffy-kyw added `awaitId:` after `timeout:`, which the argument scan now handles wherever it sits; libspiffy-64un moved the wallet coordinator's site into `awaitProjectionApplied`, shared with the payment coordinator).

import 'dart:io';
import 'package:test/test.dart';

const _files = [
  'lib/src/actors/invoice_coordinator_actor.dart',
  'lib/src/actors/payment_channel_manager_actor.dart',
  'lib/src/actors/payment_coordinator_actor.dart',
  'lib/src/actors/projection_barrier.dart',
  'lib/src/actors/wallet_coordinator_actor.dart',
];

/// Number of AwaitEventApplied ask sites the audit enumerated.
const _expectedSites = 5;

void main() {
  test('every AwaitEventApplied ask passes a timeout longer than the awaiter window',
      () {
    final sites = <_AskSite>[];
    for (final path in _files) {
      final source = _stripLineComments(File(path).readAsStringSync());
      sites.addAll(_findSites(path, source));
    }

    expect(sites, hasLength(_expectedSites),
        reason: 'expected $_expectedSites AwaitEventApplied ask sites, found: '
            '${sites.map((s) => s.location).join(', ')}');

    final problems = <String>[];
    for (final site in sites) {
      final askTimeout = site.askTimeout;
      if (askTimeout == null) {
        problems.add('${site.location}: ask() has no explicit timeout '
            '(dactor default 5 s < awaiter ${site.awaiterTimeoutExpr})');
        continue;
      }
      if (!_askOutlastsAwaiter(site.awaiterTimeoutExpr, askTimeout)) {
        problems.add('${site.location}: ask timeout "$askTimeout" does not '
            'outlast awaiter timeout "${site.awaiterTimeoutExpr}"');
      }
    }
    expect(problems, isEmpty, reason: problems.join('\n'));
  });
}

class _AskSite {
  final String location;
  final String awaiterTimeoutExpr;
  final String? askTimeout;
  _AskSite(this.location, this.awaiterTimeoutExpr, this.askTimeout);
}

String _stripLineComments(String source) => source
    .split('\n')
    .map((line) => line.replaceFirst(RegExp(r'//.*$'), ''))
    .join('\n');

List<_AskSite> _findSites(String path, String source) {
  final sites = <_AskSite>[];
  var from = 0;
  while (true) {
    final at = source.indexOf('AwaitEventApplied(', from);
    if (at == -1) break;
    from = at + 1;

    // Skip anything that is not an argument to an ask( call.
    final askOpen = source.lastIndexOf('.ask', at);
    if (askOpen == -1) continue;
    final askParen = source.indexOf('(', askOpen);
    if (askParen == -1 || askParen > at) continue;
    if (source.substring(askParen + 1, at).trim().isNotEmpty) continue;

    final awaiterOpen = at + 'AwaitEventApplied'.length;
    final awaiterClose = _matchParen(source, awaiterOpen);
    final awaiterArgs = source.substring(awaiterOpen + 1, awaiterClose);
    final awaiterTimeout =
        _namedArgument(awaiterArgs, 'timeout') ?? '<none: 30 s default>';

    final askClose = _matchParen(source, askParen);
    final rest = source.substring(awaiterClose + 1, askClose).trim();
    final askTimeout = rest.startsWith(',')
        ? rest.substring(1).trim().replaceAll(RegExp(r',\s*$'), '')
        : null;

    final line = '\n'.allMatches(source.substring(0, at)).length + 1;
    sites.add(_AskSite(
      '$path:$line',
      awaiterTimeout,
      askTimeout == null || askTimeout.isEmpty ? null : askTimeout,
    ));
  }
  return sites;
}

/// The value of the named argument [name] in [args], wherever it sits in the
/// list, or null when it is absent.
///
/// Scanned rather than matched by a regex anchored to the end of the list:
/// `timeout:` used to be the last argument, and when `awaitId:` was added
/// after it (bead libspiffy-kyw) an end-anchored pattern stopped finding it
/// and reported every site as carrying the 30 s default. The guard failed
/// closed, which is how it was noticed, but it must not depend on the order
/// its call sites happen to be written in.
String? _namedArgument(String args, String name) {
  final label = RegExp('(^|,)\\s*${RegExp.escape(name)}\\s*:');
  final match = label.firstMatch(args);
  if (match == null) return null;
  var depth = 0;
  for (var i = match.end; i < args.length; i++) {
    final c = args[i];
    if (c == '(' || c == '[' || c == '{') depth++;
    if (c == ')' || c == ']' || c == '}') depth--;
    // The value ends at the first comma that is not inside a nested call.
    if (c == ',' && depth == 0) return args.substring(match.end, i).trim();
  }
  return args.substring(match.end).trim();
}

int _matchParen(String source, int openIndex) {
  assert(source[openIndex] == '(');
  var depth = 0;
  for (var i = openIndex; i < source.length; i++) {
    final c = source[i];
    if (c == '(') depth++;
    if (c == ')') {
      depth--;
      if (depth == 0) return i;
    }
  }
  throw StateError('unbalanced parentheses at $openIndex');
}

/// True when [askTimeout] is provably longer than [awaiterTimeout]. Both
/// literal `Duration(seconds: N)` forms are compared numerically; an
/// identifier-based awaiter timeout `X` is accepted when the ask timeout
/// is `X + const Duration(...)`.
bool _askOutlastsAwaiter(String awaiterTimeout, String askTimeout) {
  final awaiterSecs = _literalSeconds(awaiterTimeout);
  final askSecs = _literalSeconds(askTimeout);
  if (awaiterSecs != null && askSecs != null) return askSecs > awaiterSecs;

  final ident = RegExp(r'^[A-Za-z_]\w*$').firstMatch(awaiterTimeout)?.group(0);
  if (ident != null) {
    final plus = RegExp('^${RegExp.escape(ident)}\\s*\\+\\s*(const\\s+)?Duration\\(')
        .hasMatch(askTimeout);
    return plus;
  }
  return false;
}

int? _literalSeconds(String expr) {
  final m = RegExp(r'^(?:const\s+)?Duration\(\s*seconds:\s*(\d+)\s*\)$')
      .firstMatch(expr.trim());
  return m == null ? null : int.parse(m.group(1)!);
}
