import 'package:flutter/material.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../theme.dart';
import '../widgets/wizard.dart';
import 'login_screen.dart';

/// Contact flag for a favourite node (the firmware's `ContactInfo::isFav()`).
/// The app never changes it; it only uses it to order the picker.
const int _contactFlagFavorite = 0x01;

/// Step 2: choose the node to update. The admin login is deliberately a
/// separate step — with a long contact list the password field sat below the
/// fold, and the key can be (and the pubkey tab makes it easy to) chosen
/// without one.
class TargetScreen extends StatefulWidget {
  const TargetScreen({super.key});

  @override
  State<TargetScreen> createState() => _TargetScreenState();
}

class _TargetScreenState extends State<TargetScreen> {
  bool _showAll = false;
  String _manualKey = '';
  String _search = '';
  final _manualController = TextEditingController();
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _manualController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final selected = app.target;

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Pick a repeater'),
          bottom: const WizardTabBar(
            step: 2,
            label: 'Pick the repeater',
            tabs: [
              Tab(text: 'Repeaters'),
              Tab(text: 'Public key'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _buildRepeaterTab(app, selected),
            _buildManualTab(app),
          ],
        ),
        bottomNavigationBar: WizardFooter(
          label: 'Sign in',
          onPressed: selected == null
              ? null
              : () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const LoginScreen()),
                  ),
          hint: selected == null
              ? 'Choose a repeater above, or enter its public key.'
              : null,
        ),
      ),
    );
  }

  Widget _buildRepeaterTab(AppState app, Contact? selected) {
    final repeaters =
        app.contacts.where((c) => c.advType == advTypeRepeater).toList();
    final visible = _showAll ? app.contacts : repeaters;
    final query = _search.trim().toLowerCase();
    final keyQuery = query.replaceAll(RegExp(r'\s'), '');
    final matches = _sortContacts(
      visible.where((c) => _matches(c, query, keyQuery)),
    );

    return ListView(
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: TextField(
            key: const Key('repeater-search'),
            controller: _searchController,
            decoration: InputDecoration(
              labelText: 'Search repeaters',
              hintText: 'Name or public key',
              prefixIcon: const Icon(Icons.search),
              isDense: true,
              suffixIcon: _search.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear search',
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _search = '');
                      },
                    ),
            ),
            autocorrect: false,
            enableSuggestions: false,
            onChanged: (value) => setState(() => _search = value),
          ),
        ),
        if (matches.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              _search.trim().isEmpty
                  ? 'No repeater contacts on this companion yet. Advertise '
                      'from the repeater (or wait for its periodic advert), '
                      'or use the Public key tab.'
                  : 'No repeaters match "$_search". Try another name or part '
                      'of a key, or use the Public key tab.',
              style: const TextStyle(
                  color: OtaTheme.textMuted, fontSize: 12, height: 1.4),
            ),
          ),
        ...matches.map(
          (c) => Card(
            color: _sameKey(selected, c) ? OtaTheme.surfaceHigh : null,
            child: ListTile(
              leading: Icon(
                c.advType == advTypeRepeater
                    ? Icons.cell_tower
                    : Icons.device_hub_outlined,
                color: OtaTheme.accent,
              ),
              title: Text(c.name.isNotEmpty ? c.name : '(unnamed)'),
              subtitle: Text(
                _subtitle(c),
                style: const TextStyle(color: OtaTheme.textMuted, fontSize: 11),
              ),
              trailing: _sameKey(selected, c)
                  ? const Icon(Icons.radio_button_checked,
                      color: OtaTheme.accent)
                  : null,
              onTap: () => app.selectTarget(c),
            ),
          ),
        ),
        if (repeaters.length != app.contacts.length)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextButton.icon(
              onPressed: () => setState(() => _showAll = !_showAll),
              icon: Icon(_showAll ? Icons.expand_less : Icons.expand_more),
              label:
                  Text(_showAll ? 'Show repeaters only' : 'Show all contacts'),
            ),
          ),
      ],
    );
  }

  /// Favourites and nodes with a saved route come first, so the ones the
  /// companion can actually reach are visible without scrolling. Within a
  /// group the order is alphabetical, with unnamed contacts last.
  List<Contact> _sortContacts(Iterable<Contact> contacts) {
    final sorted = contacts.toList();
    sorted.sort((a, b) {
      final rank = _rank(a).compareTo(_rank(b));
      if (rank != 0) return rank;
      final name = _sortName(a).compareTo(_sortName(b));
      if (name != 0) return name;
      return a.publicKeyHex.compareTo(b.publicKeyHex);
    });
    return sorted;
  }

  /// Lower rank means higher in the list. A zero-hop route sorts ahead of a
  /// multi-hop route because it needs no relay.
  int _rank(Contact c) {
    final favourite = c.flags & _contactFlagFavorite != 0;
    final hops = c.hasDirectRoute ? c.outPathLen & 0x3F : -1;
    if (favourite) return hops == 0 ? 0 : (hops > 0 ? 1 : 2);
    return hops == 0 ? 3 : (hops > 0 ? 4 : 5);
  }

  String _sortName(Contact c) {
    final name = c.name.trim().toLowerCase();
    return name.isEmpty ? '\uffff' : name;
  }

  bool _matches(Contact c, String query, String keyQuery) {
    if (query.isEmpty) return true;
    if (c.name.toLowerCase().contains(query)) return true;
    // A single hex digit matches almost every key, so require a short run.
    return keyQuery.length >= 2 && c.publicKeyHex.contains(keyQuery);
  }

  String _subtitle(Contact c) {
    final favourite = c.flags & _contactFlagFavorite != 0;
    return favourite ? 'favorite, ${_pathLabel(c)}' : _pathLabel(c);
  }

  Widget _buildManualTab(AppState app) {
    final selected = app.target;
    final valid = RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(_manualKey);
    return ListView(
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 14, 16, 0),
          child: Text(
            'Paste the repeater\'s public key (64 hex characters) for a node '
            'this companion does not know.',
            style: TextStyle(
                color: OtaTheme.textMuted, fontSize: 12, height: 1.45),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 14, 12, 0),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _manualController,
                    decoration: const InputDecoration(
                      labelText: 'Public key (64 hex chars)',
                      isDense: true,
                    ),
                    autocorrect: false,
                    enableSuggestions: false,
                    onChanged: (value) => setState(() {
                      _manualKey =
                          value.trim().toLowerCase().replaceAll(' ', '');
                    }),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton(
                    onPressed: !valid
                        ? null
                        : () {
                            app.addManualTarget(_manualKey,
                                name: 'manual node');
                            FocusScope.of(context).unfocus();
                          },
                    child: const Text('Use this node'),
                  ),
                  if (selected != null && !valid) ...[
                    const SizedBox(height: 12),
                    Text(
                      'Selected: '
                      '${selected.name.isNotEmpty ? selected.name : '(unnamed)'}',
                      style: const TextStyle(
                          color: OtaTheme.textMuted, fontSize: 12),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  static bool _sameKey(Contact? a, Contact b) {
    if (a == null || a.publicKey.length != b.publicKey.length) return false;
    for (var i = 0; i < a.publicKey.length; i++) {
      if (a.publicKey[i] != b.publicKey[i]) return false;
    }
    return true;
  }

  String _pathLabel(Contact c) {
    if (!c.hasDirectRoute) return 'no saved route';
    final hops = c.outPathLen & 0x3F;
    if (hops == 0) return 'direct';
    return 'direct, $hops hop(s)';
  }
}
