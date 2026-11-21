import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Per-repeater path override, available from the hub and every management
/// screen. It replaces the OTA-only path field: the same path is used by
/// settings, status and CLI commands because it is pushed to the companion's
/// saved contact record.
class RoutingSheet extends StatefulWidget {
  const RoutingSheet({super.key});

  @override
  State<RoutingSheet> createState() => _RoutingSheetState();
}

class _RoutingSheetState extends State<RoutingSheet> {
  late final TextEditingController _controller;
  String? _outcome;

  @override
  void initState() {
    super.initState();
    _controller =
        TextEditingController(text: context.read<AppState>().manualRoutePath);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final value = _controller.text.trim();
    final mode = value.isEmpty
        ? _RouteMode.zeroHop
        : value == '0'
            ? _RouteMode.direct
            : _RouteMode.custom;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.72,
      maxChildSize: 0.92,
      builder: (context, controller) => ListView(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          Row(
            children: [
              const Icon(Icons.route, color: OtaTheme.accent),
              const SizedBox(width: 10),
              const Expanded(
                child: Text('Repeater route',
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              ),
              IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close),
                tooltip: 'Close',
              ),
            ],
          ),
          if (app.target != null)
            InfoRow(label: 'Repeater', value: app.target!.name),
          const SizedBox(height: 8),
          const Text(
            'How messages reach this repeater. A longer path uses more mesh '
            'airtime. Changing it here also changes the path used by the '
            'firmware update.',
            style:
                TextStyle(color: OtaTheme.textMuted, fontSize: 12, height: 1.3),
          ),
          const SectionHeader('Route type'),
          SegmentedButton<_RouteMode>(
            segments: const [
              ButtonSegment(value: _RouteMode.zeroHop, label: Text('Zero hop')),
              ButtonSegment(value: _RouteMode.direct, label: Text('Direct')),
              ButtonSegment(value: _RouteMode.custom, label: Text('Via hops')),
            ],
            selected: {mode},
            onSelectionChanged: (selected) {
              final next = selected.first;
              setState(() {
                _controller.text = switch (next) {
                  _RouteMode.zeroHop => '',
                  _RouteMode.direct => '0',
                  _RouteMode.custom => 'c0ff',
                };
                _outcome = null;
              });
              app.setManualRoutePath(_controller.text);
            },
          ),
          if (mode == _RouteMode.custom) ...[
            const SizedBox(height: 12),
            TextField(
              key: const Key('routing-path'),
              controller: _controller,
              autocorrect: false,
              onChanged: (v) {
                app.setManualRoutePath(v);
                setState(() => _outcome = null);
              },
              decoration: InputDecoration(
                labelText: 'Path hashes, e.g. c0ff,c0c0',
                border: const OutlineInputBorder(),
                errorText: app.manualRouteError,
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                'Each hop is 2 to 6 hex digits. All hops must be the same '
                'size. Use 0 for a direct route.',
                style: TextStyle(color: OtaTheme.textMuted, fontSize: 11),
              ),
            ),
          ],
          if (_outcome != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(_outcome!,
                  style: const TextStyle(color: OtaTheme.warn, fontSize: 12)),
            ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: app.manualRouteError != null
                ? null
                : () async {
                    final result = await app.applyRoute();
                    if (!mounted) return;
                    setState(() => _outcome = result ?? 'Route applied.');
                  },
            icon: const Icon(Icons.check),
            label: const Text('Apply route'),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () {
              _controller.clear();
              app.setManualRoutePath('');
              setState(() => _outcome = null);
            },
            child: const Text('Clear override'),
          ),
        ],
      ),
    );
  }
}

enum _RouteMode { zeroHop, direct, custom }

/// Open the routing sheet from any screen. The same button is used on the hub
/// and in the management scaffold so operators learn one control.
Future<void> showRoutingSheet(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const RoutingSheet(),
    );
