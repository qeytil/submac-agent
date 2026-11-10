import sys, pathlib

def patch(path, old, new):
    p = pathlib.Path(path); s = p.read_text(); n = s.count(old)
    if n != 1:
        print("::error file=%s::pattern found %d times" % (path, n)); sys.exit(1)
    p.write_text(s.replace(old, new)); print("patched", path)

H = "lib/screens/home_screen.dart"
patch(H,
"""            // Replies left: only while billing is on (zero width otherwise).
            middle: const WalletChip(),
""",
"""            middle: const SizedBox.shrink(),
""")
patch(H, "import 'billing/billing_widgets.dart';\n", "")
patch(H,
"""/// Today at a glance: how much is left, in plain words. No tokens, no model names.
Future<void> showTodaySheet(BuildContext context) async {
  unawaited(Cloud.refreshStatus(force: true));
  await showModalBottomSheet<void>(
    sheetAnimationStyle: SubMotion.sheet,
    context: context,
    showDragHandle: true,
    builder: (ctx) => const TodayUsage(padding: EdgeInsetsDirectional.fromSTEB(20, 0, 20, 28)),
  );
}""",
"""/// BYOK only: there is no cloud allowance to show any more (the long-press menu is unchanged).
Future<void> showTodaySheet(BuildContext context) async {}""")

M = "lib/widgets/message_view.dart"
patch(M,
"""    // Billing refusal (limit, paid model, payment confirming...): its own card with the reason, reset time and options.
    final notice = Billing.I.noticeFor(ErrorCopy.detail(widget.raw));
    if (notice != null) return BillingNoticeCard(notice: notice, isLast: widget.isLast, onRetry: () => state.regenerate());
""",
"")
patch(M,
"""import '../services/billing/billing_service.dart';
import '../screens/billing/billing_notice_sheet.dart';
""",
"")
