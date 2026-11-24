import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:get/get.dart';

const String kLocalOptionServerProfiles = 'server-profiles';

class ServerProfile {
  String name;
  ServerConfig config;

  ServerProfile(this.name, this.config);

  Map<String, String> toJson() => {
        'name': name,
        'host': config.idServer,
        'relay': config.relayServer,
        'api': config.apiServer,
        'key': config.key,
      };

  static ServerProfile fromJson(Map<String, dynamic> json) => ServerProfile(
      (json['name'] ?? '').toString(),
      ServerConfig(
          idServer: (json['host'] ?? '').toString(),
          relayServer: (json['relay'] ?? '').toString(),
          apiServer: (json['api'] ?? '').toString(),
          key: (json['key'] ?? '').toString()));

  bool sameServer(ServerConfig other) =>
      _norm(config.idServer) == _norm(other.idServer) &&
      _norm(config.relayServer) == _norm(other.relayServer) &&
      _norm(config.apiServer) == _norm(other.apiServer) &&
      config.key.trim() == other.key.trim();

  static String _norm(String s) {
    s = s.trim();
    return s.endsWith('/') ? s.substring(0, s.length - 1) : s;
  }
}

List<ServerProfile> decodeServerProfiles(String text) {
  if (text.trim().isEmpty) return [];
  try {
    final list = jsonDecode(text);
    if (list is! List) return [];
    return list
        .whereType<Map>()
        .map((e) => ServerProfile.fromJson(Map<String, dynamic>.from(e)))
        .where((p) => p.name.isNotEmpty)
        .toList();
  } catch (e) {
    debugPrint('Invalid server profiles: $e');
    return [];
  }
}

String encodeServerProfiles(List<ServerProfile> profiles) =>
    jsonEncode(profiles.map((e) => e.toJson()).toList());

int indexOfServerProfile(List<ServerProfile> profiles, ServerConfig current) =>
    profiles.indexWhere((p) => p.sameServer(current));

class ServerProfiles {
  static final ServerProfiles instance = ServerProfiles._();
  ServerProfiles._() {
    profiles.value = decodeServerProfiles(
        bind.mainGetLocalOption(key: kLocalOptionServerProfiles));
  }

  final RxList<ServerProfile> profiles = <ServerProfile>[].obs;
  final Rx<ServerConfig> current = ServerConfig().obs;
  final RxBool switching = false.obs;

  static bool get hidden =>
      bind.mainGetBuildinOption(key: kOptionHideServerSetting) == 'Y' ||
      isOptionFixed('custom-rendezvous-server');

  Future<void> refresh() async {
    try {
      current.value =
          ServerConfig.fromOptions(jsonDecode(await bind.mainGetOptions()));
    } catch (e) {
      debugPrint('Failed to read server options: $e');
    }
  }

  int get currentIndex => indexOfServerProfile(profiles, current.value);

  Future<void> _save() async {
    await bind.mainSetLocalOption(
        key: kLocalOptionServerProfiles, value: encodeServerProfiles(profiles));
  }

  Future<void> saveCurrentAs(String name) async {
    await refresh();
    final c = current.value;
    final copy = ServerConfig(
        idServer: c.idServer,
        relayServer: c.relayServer,
        apiServer: c.apiServer,
        key: c.key);
    final i = profiles.indexWhere((p) => p.name == name);
    if (i >= 0) {
      profiles[i] = ServerProfile(name, copy);
    } else {
      profiles.add(ServerProfile(name, copy));
    }
    await _save();
  }

  Future<void> remove(int index) async {
    if (index < 0 || index >= profiles.length) return;
    profiles.removeAt(index);
    await _save();
  }

  Future<void> apply(int index) async {
    if (index < 0 || index >= profiles.length || switching.value) return;
    final c = profiles[index].config;
    switching.value = true;
    try {
      final ok = await setServerConfig(
          null,
          null,
          ServerConfig(
              idServer: c.idServer,
              relayServer: c.relayServer,
              apiServer: c.apiServer,
              key: c.key));
      await refresh();
      showToast(translate(ok ? 'Successful' : 'Failed'));
    } finally {
      switching.value = false;
    }
  }
}

/// Dropdown of saved servers; choosing one switches to it at once.
class ServerProfileSelector extends StatefulWidget {
  final bool enabled;
  final bool showManageButtons;

  const ServerProfileSelector(
      {Key? key, this.enabled = true, this.showManageButtons = false})
      : super(key: key);

  @override
  State<ServerProfileSelector> createState() => _ServerProfileSelectorState();
}

class _ServerProfileSelectorState extends State<ServerProfileSelector> {
  final model = ServerProfiles.instance;

  @override
  void initState() {
    super.initState();
    model.refresh();
  }

  @override
  void didUpdateWidget(covariant ServerProfileSelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    model.refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final profiles = model.profiles.toList();
      model.current.value;
      final index = model.currentIndex;
      final enabled = widget.enabled && !model.switching.value;
      final dropdown = DropdownButton<int>(
        isExpanded: true,
        isDense: true,
        underline: const SizedBox.shrink(),
        value: index >= 0 ? index : null,
        hint: Text(
          translate(profiles.isEmpty ? 'No saved servers' : 'Not saved'),
          overflow: TextOverflow.ellipsis,
        ),
        items: [
          for (var i = 0; i < profiles.length; i++)
            DropdownMenuItem<int>(
              value: i,
              child: Tooltip(
                message: _describe(profiles[i].config),
                waitDuration: const Duration(milliseconds: 800),
                child: Text(profiles[i].name, overflow: TextOverflow.ellipsis),
              ),
            ),
        ],
        onChanged: enabled && profiles.isNotEmpty
            ? (i) {
                if (i != null && i != index) model.apply(i);
              }
            : null,
      );
      if (!widget.showManageButtons) return dropdown;
      return Row(
        children: [
          Expanded(child: dropdown),
          IconButton(
            tooltip: translate('Save current server'),
            icon: const Icon(Icons.add),
            onPressed: enabled ? () => _askName(context, index) : null,
          ),
          IconButton(
            tooltip: translate('Delete'),
            icon: const Icon(Icons.delete_outline),
            onPressed: enabled && index >= 0 ? () => model.remove(index) : null,
          ),
        ],
      );
    });
  }

  static String _describe(ServerConfig c) {
    final lines = <String>[
      '${translate('ID Server')}: ${c.idServer.isEmpty ? '-' : c.idServer}',
      '${translate('Relay Server')}: ${c.relayServer.isEmpty ? '-' : c.relayServer}',
      '${translate('API Server')}: ${c.apiServer.isEmpty ? '-' : c.apiServer}',
    ];
    return lines.join('\n');
  }

  void _askName(BuildContext context, int index) {
    final ctrl = TextEditingController(
        text: index >= 0
            ? model.profiles[index].name
            : model.current.value.idServer);
    gFFI.dialogManager.show((setState, close, context) {
      submit() async {
        final name = ctrl.text.trim();
        if (name.isEmpty) return;
        close();
        await model.saveCurrentAs(name);
        showToast(translate('Successful'));
      }

      return CustomAlertDialog(
        title: Text(translate('Save current server')),
        content: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 400),
          child: TextField(
            controller: ctrl,
            autofocus: true,
            decoration: InputDecoration(labelText: translate('Name')),
            onSubmitted: (_) => submit(),
          ),
        ),
        actions: [
          dialogButton('Cancel', onPressed: close, isOutline: true),
          dialogButton('OK', onPressed: submit),
        ],
        onSubmit: submit,
        onCancel: close,
      );
    });
  }
}
