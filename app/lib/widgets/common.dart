import 'package:flutter/material.dart';

import '../theme.dart';

/// Small shared building blocks so every screen reads the same.

/// The same monochrome icon always means the same action, on every screen.
/// Buttons tint them with their own foreground color, so they follow the
/// theme instead of rendering as colored emoji.
const IconData nextIcon = Icons.arrow_forward;
const IconData playIcon = Icons.play_arrow;
const IconData pauseIcon = Icons.pause;
const IconData stopIcon = Icons.stop;
const IconData backIcon = Icons.arrow_back;
const IconData updateIcon = Icons.system_update;
const IconData settingsIcon = Icons.tune;
const IconData repeaterIcon = Icons.cell_tower;
const IconData fleetIcon = Icons.groups_outlined;
const IconData libraryIcon = Icons.inventory_2_outlined;

/// One size format everywhere in the app.
String formatBytes(int bytes) => bytes >= 1024 * 1024
    ? '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB'
    : '${(bytes / 1024).toStringAsFixed(0)} KB';

class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
      child: Text(
        title.toUpperCase(),
        style: const TextStyle(
          color: OtaTheme.textMuted,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

class InfoRow extends StatelessWidget {
  const InfoRow(
      {super.key, required this.label, required this.value, this.mono = true});

  final String label;
  final String value;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 118,
            child: Text(
              label,
              style: const TextStyle(color: OtaTheme.textMuted, fontSize: 12),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 13,
                fontFamily: mono ? 'monospace' : null,
                color: const Color(0xFFE2E8F0),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ErrorBanner extends StatelessWidget {
  const ErrorBanner(this.message, {super.key});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: OtaTheme.bad.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: OtaTheme.bad.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, color: OtaTheme.bad, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: OtaTheme.bad, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

/// One relative-age label for every cached value in the app.
String formatAge(DateTime at, {DateTime? now}) {
  final seconds = (now ?? DateTime.now()).difference(at).inSeconds;
  if (seconds < 45) return 'just now';
  if (seconds < 3600) return '${seconds ~/ 60} min ago';
  if (seconds < 86400) return '${seconds ~/ 3600} h ago';
  return '${seconds ~/ 86400} d ago';
}

class LastKnownLabel extends StatelessWidget {
  const LastKnownLabel(this.fetchedAt, {super.key, this.prefix = 'Last known'});

  final DateTime fetchedAt;
  final String prefix;

  @override
  Widget build(BuildContext context) => Text(
        '$prefix ${formatAge(fetchedAt)}',
        style: const TextStyle(color: OtaTheme.textMuted, fontSize: 11),
      );
}

/// Every activity tile on the hub and in management screens uses this shape.
class ActivityTile extends StatelessWidget {
  const ActivityTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
    this.badge,
    this.locked = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final String? badge;
  final bool locked;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        enabled: onTap != null,
        label: locked ? '$title, locked. $subtitle' : '$title. $subtitle',
        child: Card(
          child: ExcludeSemantics(
            child: ListTile(
              leading: Icon(locked ? Icons.lock_outline : icon,
                  color: locked ? OtaTheme.textMuted : OtaTheme.accent),
              title: Text(title),
              subtitle: Text(subtitle,
                  style: const TextStyle(
                      color: OtaTheme.textMuted, fontSize: 12, height: 1.3)),
              trailing: badge == null
                  ? const Icon(Icons.chevron_right, color: OtaTheme.textMuted)
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        StatusPill(badge!,
                            color: locked ? OtaTheme.textMuted : OtaTheme.ok),
                        const Icon(Icons.chevron_right,
                            color: OtaTheme.textMuted, size: 18),
                      ],
                    ),
              onTap: onTap,
            ),
          ),
        ),
      );
}

class StatusPill extends StatelessWidget {
  const StatusPill(this.label, {super.key, this.color = OtaTheme.accent});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Text(
        label,
        style:
            TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700),
      ),
    );
  }
}
