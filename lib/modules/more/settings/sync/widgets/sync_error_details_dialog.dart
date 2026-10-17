import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mangayomi/core/navigation/app_navigator.dart';
import 'package:mangayomi/eval/model/m_bridge.dart';
import 'package:mangayomi/services/crash_report.dart';

/// Shows a fixed sync failure [message] with a Details link that opens the
/// redacted error and stack trace in [SyncErrorDetailsDialog].
void showSyncFailureToast(String message, Object error, StackTrace? stack) {
  final details = syncErrorDetails(error, stack);
  botToast(
    message,
    second: 8,
    detailsLabel: 'Details',
    onDetails: () => AppNavigator.showAppDialog<void>(
      (_) => SyncErrorDetailsDialog(details: details),
    ),
  );
}

/// Shareable text for a failed sync: the error type, its message and the
/// first frames of its stack, passed through the crash-report redaction so
/// URLs keep only their host and credentials and home paths are removed.
String syncErrorDetails(
  Object error,
  StackTrace? stack, {
  int maxStackLines = 24,
}) {
  final lines = [
    'Error: ${error.runtimeType}',
    redact(error.toString()).trim(),
  ];
  final frames = stack == null
      ? const <String>[]
      : redact(stack.toString())
            .split('\n')
            .where((line) => line.trim().isNotEmpty)
            .toList(growable: false);
  if (frames.isNotEmpty) {
    lines
      ..add('')
      ..add('Stack:')
      ..addAll(frames.take(maxStackLines));
    if (frames.length > maxStackLines) {
      lines.add('… ${frames.length - maxStackLines} more frame(s)');
    }
  }
  return lines.join('\n');
}

/// Shows [details] in a read-only text box that can be scrolled, selected
/// and copied.
class SyncErrorDetailsDialog extends StatefulWidget {
  const SyncErrorDetailsDialog({super.key, required this.details});

  final String details;

  @override
  State<SyncErrorDetailsDialog> createState() => _SyncErrorDetailsDialogState();
}

class _SyncErrorDetailsDialogState extends State<SyncErrorDetailsDialog> {
  late final _controller = TextEditingController(text: widget.details);
  var _copied = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.details));
    if (mounted) setState(() => _copied = true);
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return AlertDialog(
      title: const Text('Sync error details'),
      content: SizedBox(
        width: size.width < 640 ? size.width : 560,
        height: size.height * 0.5,
        child: TextField(
          controller: _controller,
          readOnly: true,
          expands: true,
          maxLines: null,
          textAlignVertical: TextAlignVertical.top,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            helperText: 'Links, paths and credentials are removed.',
          ),
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: _copy,
          icon: Icon(_copied ? Icons.check : Icons.copy),
          label: Text(_copied ? 'Copied' : 'Copy'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
