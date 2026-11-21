import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:provider/provider.dart';
import 'package:repeater_core/repeater_core.dart';

import '../../app_state.dart';
import '../../services/cli_service.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import '../../widgets/management.dart';

/// Change the repeater's private key. This is the most destructive management
/// action: the node's public key changes, it reboots, and the local directory
/// and cache must move with it.
class IdentityKeyScreen extends StatefulWidget {
  const IdentityKeyScreen({super.key, this.cli});

  final CliService? cli;

  @override
  State<IdentityKeyScreen> createState() => _IdentityKeyScreenState();
}

class _IdentityKeyScreenState extends State<IdentityKeyScreen> {
  final _key = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  String? _problem;
  String? _newPublicKey;

  @override
  void dispose() {
    _key.dispose();
    _confirm.dispose();
    super.dispose();
  }

  String? get _validation {
    final hex = _key.text.trim();
    if (!RegExp(r'^[0-9a-fA-F]{128}$').hasMatch(hex)) {
      return 'Enter the 128 hex characters of a MeshCore private key.';
    }
    if (_confirm.text.trim() != 'CHANGE IDENTITY') {
      return 'Type CHANGE IDENTITY to confirm.';
    }
    return null;
  }

  Future<void> _apply() async {
    final error = _validation;
    if (error != null) {
      setState(() => _problem = error);
      return;
    }
    final app = context.read<AppState>();
    final cli = widget.cli ?? app.managementCli();
    final target = app.target;
    if (cli == null || target == null) return;
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      final bytes = hexToBytes(_key.text.trim());
      final identity = await LocalIdentity.import(bytes);
      final newHex = bytesToHex(identity.publicKey);
      final reply = await cli.write(target, 'set prv.key ${_key.text.trim()}',
          family: 'identity');
      if (!reply.ok) {
        setState(() => _problem = reply.kind == CliReplyKind.unknown
            ? 'No answer. Outcome unknown; check the node after reboot.'
            : reply.text);
        return;
      }
      final oldHex = target.publicKeyHex;
      await app.directory?.migrateIdentity(oldHex, newHex);
      app.selectTarget(Contact(
        publicKey: Uint8List.fromList(identity.publicKey),
        name: target.name,
        advType: target.advType,
      ));
      await app.identifyCapabilities(force: true);
      if (mounted) {
        setState(() {
          _newPublicKey = newHex;
          _key.clear();
          _confirm.clear();
        });
      }
    } catch (e) {
      if (mounted) setState(() => _problem = 'Could not change identity: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ManagementScaffold(
        title: 'Change node identity',
        refreshing: _busy,
        footer: FilledButton.icon(
          onPressed: _busy || _validation != null ? null : _apply,
          icon: const Icon(Icons.key),
          label: const Text('Change identity'),
        ),
        children: [
          if (_problem != null) ErrorBanner(_problem!),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              'The repeater will get a new public key and reboot. Its local '
              'directory and cached settings move to the new key. Contact '
              'everyone who uses the old key.',
              style: TextStyle(color: OtaTheme.bad, fontSize: 12),
            ),
          ),
          if (_newPublicKey != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: InfoRow(label: 'New public key', value: _newPublicKey!),
            ),
          const SectionHeader('New private key'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              key: const Key('identity-key'),
              controller: _key,
              obscureText: true,
              autocorrect: false,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: '128 hex characters',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          const SectionHeader('Confirm'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              key: const Key('identity-confirm'),
              controller: _confirm,
              autocorrect: false,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Type CHANGE IDENTITY',
                border: OutlineInputBorder(),
              ),
            ),
          ),
        ],
      );
}
