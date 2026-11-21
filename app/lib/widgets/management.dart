import 'package:flutter/material.dart';
import 'package:repeater_core/repeater_core.dart';

import '../theme.dart';
import 'common.dart' show LastKnownLabel;

/// Shared chrome for the single-repeater management activities. Every screen
/// uses the same app bar, refresh affordance and last-known language.
class ManagementScaffold extends StatelessWidget {
  const ManagementScaffold({
    super.key,
    required this.title,
    required this.children,
    this.onRefresh,
    this.refreshing = false,
    this.actions = const [],
    this.footer,
  });

  final String title;
  final List<Widget> children;
  final VoidCallback? onRefresh;
  final bool refreshing;
  final List<Widget> actions;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final bar = footer;
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          if (onRefresh != null)
            IconButton(
              onPressed: refreshing ? null : onRefresh,
              icon: refreshing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
              tooltip: 'Refresh',
            ),
          ...actions,
        ],
        bottom: refreshing
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : null,
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: children,
      ),
      bottomNavigationBar: bar == null
          ? null
          : Material(
              color: OtaTheme.surface,
              child: SafeArea(
                minimum: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                child: bar,
              ),
            ),
    );
  }
}

/// One input control for a setting, shared by the curated screen and the
/// generic browser so validation and layout stay identical.
class SettingField extends StatelessWidget {
  const SettingField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.input = SettingInput.text,
    this.choices,
    this.error,
    this.help,
  });

  final String label;
  final String? value;
  final ValueChanged<String> onChanged;
  final SettingInput input;
  final List<String>? choices;
  final String? error;
  final String? help;

  @override
  Widget build(BuildContext context) {
    final control = switch (input) {
      SettingInput.toggle => Switch(
          value: value?.toLowerCase() == 'on',
          onChanged: (v) => onChanged(v ? 'on' : 'off'),
        ),
      SettingInput.choice when choices != null && choices!.isNotEmpty =>
        DropdownButton<String>(
          value: choices!.contains(value) ? value : choices!.first,
          items: [
            for (final c in choices!) DropdownMenuItem(value: c, child: Text(c))
          ],
          onChanged: (v) => v == null ? null : onChanged(v),
        ),
      _ => TextField(
          controller: TextEditingController(text: value ?? ''),
          onChanged: onChanged,
          autocorrect: false,
          keyboardType: input == SettingInput.number
              ? TextInputType.number
              : TextInputType.text,
          decoration: InputDecoration(
            isDense: true,
            border: const OutlineInputBorder(),
            errorText: error,
          ),
        ),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(label,
                    style: const TextStyle(
                        fontSize: 12, color: OtaTheme.textMuted)),
              ),
              if (input == SettingInput.toggle || input == SettingInput.choice)
                control,
            ],
          ),
          if (input != SettingInput.toggle && input != SettingInput.choice) ...[
            const SizedBox(height: 4),
            control,
          ],
          if (help != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(help!,
                  style:
                      const TextStyle(fontSize: 11, color: OtaTheme.textMuted)),
            ),
        ],
      ),
    );
  }
}

/// A value with its own refresh button and a last-known age, used wherever a
/// section can be refreshed independently.
class RefreshableValue extends StatelessWidget {
  const RefreshableValue({
    super.key,
    required this.label,
    required this.value,
    this.fetchedAt,
    this.onRefresh,
    this.busy = false,
  });

  final String label;
  final String value;
  final DateTime? fetchedAt;
  final VoidCallback? onRefresh;
  final bool busy;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 118,
              child: Text(label,
                  style:
                      const TextStyle(color: OtaTheme.textMuted, fontSize: 12)),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(value,
                      style: const TextStyle(
                          fontSize: 13,
                          fontFamily: 'monospace',
                          color: Color(0xFFE2E8F0))),
                  if (fetchedAt != null) LastKnownLabel(fetchedAt!),
                ],
              ),
            ),
            if (onRefresh != null)
              IconButton(
                onPressed: busy ? null : onRefresh,
                icon: const Icon(Icons.refresh, size: 18),
                tooltip: 'Refresh $label',
                visualDensity: VisualDensity.compact,
              ),
          ],
        ),
      );
}
